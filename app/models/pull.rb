class Pull < ActiveRecord::Base
  include Redmine::SafeAttributes

  belongs_to :project
  belongs_to :repository
  belongs_to :author, :class_name => 'User'
  belongs_to :assigned_to, :class_name => 'Principal'
  belongs_to :priority, :class_name => 'IssuePriority'
  belongs_to :category, :class_name => 'IssueCategory'

  has_many :journals, :as => :journalized, :dependent => :destroy, :inverse_of => :journalized

  acts_as_customizable
  acts_as_watchable
  acts_as_searchable :columns => ['subject', "#{table_name}.description"],
                     :preload => [:project],
                     :scope => lambda {|options| options[:open_pulls] ? self.open : self.all}

  acts_as_event :title => Proc.new {|o| l(:label_pull_request) + " ##{o.id}: #{o.subject}"},
                :url => Proc.new {|o| {:controller => 'pulls', :action => 'show', :id => o.id}},
                :type => Proc.new {|o| 'pull' + (o.closed? ? '-closed' : '') }

  acts_as_activity_provider :scope => preload(:project, :author),
                            :author_key => :author_id

  attr_reader :current_journal
  delegate :notes, :notes=, :private_notes, :private_notes=, :to => :current_journal, :allow_nil => true

  validates_presence_of :subject, :project, :commit_base, :commit_compare
  validates_presence_of :priority, :if => Proc.new {|issue| issue.new_record? || issue.priority_id_changed?}
  validates_presence_of :author, :if => Proc.new {|issue| issue.new_record? || issue.author_id_changed?}

  validates_length_of :subject, :maximum => 255
  attr_protected :id

  scope :open, lambda {|*args|
    is_closed = args.size > 0 ? !args.first : false

    if is_closed
      where.not(:closed_on => nil)
    else
      where(:closed_on => nil)
    end
  }

  scope :recently_updated, lambda { order(:updated_on => :desc) }

  scope :on_active_project, lambda {
    joins(:project).
      where(:projects => {:status => Project::STATUS_ACTIVE})
  }

  scope :assigned_to, lambda {|arg|
    arg = Array(arg).uniq
    ids = arg.map {|p| p.is_a?(Principal) ? p.id : p}
    ids += arg.select {|p| p.is_a?(User)}.map(&:group_ids).flatten.uniq
    ids.compact!
    ids.any? ? where(:assigned_to_id => ids) : none
  }

  scope :like, lambda {|q|
    q = q.to_s
    if q.present?
      where("LOWER(#{table_name}.subject) LIKE LOWER(?)", "%#{q}%")
    end
  }

  before_save :force_updated_on_change, :update_closed_on, :set_assigned_to_was
  after_save :create_journal
  after_create :send_notification

# Returns true if user or current user is allowed to edit or add notes to the issue
  def editable?(user=User.current)
    attributes_editable?(user) || notes_addable?(user)
  end

# Returns true if user or current user is allowed to edit the issue
  def attributes_editable?(user=User.current)
    user_permission?(user, :edit_pulls)
  end

# Returns true if user or current user is allowed to add notes to the issue
  def notes_addable?(user=User.current)
    user_permission?(user, :add_pull_notes)
  end

# Returns true if user or current user is allowed to delete the issue
  def deletable?(user=User.current)
    user_permission?(user, :delete_pulls)
  end

  def initialize(attributes=nil, *args)
    super
    if new_record?
      # set default values for new records only
      self.priority ||= IssuePriority.default
      self.watcher_user_ids = []
    end
  end

  def priority_id=(pid)
    self.priority = nil
    write_attribute(:priority_id, pid)
  end

  def category_id=(cid)
    self.category = nil
    write_attribute(:category_id, cid)
  end

  def repository_id=(cid)
    self.repository = nil
    write_attribute(:repository_id, cid)
  end

  def project_id=(project_id)
    if project_id.to_s != self.project_id.to_s
      self.project = (project_id.present? ? Project.find_by_id(project_id) : nil)
    end
    self.project_id
  end

# Sets the project.
# This will:
# * set the category to the category with the same name in the new
#   project if it exists, or clear it if it doesn't.
  def project=(project, keep_tracker=false)
    project_was = self.project
    association(:project).writer(project)

    if project != project_was
      @safe_attribute_names = nil
    end

    if project_was && project && project_was != project
      @assignable_versions = nil

      # Reassign to the category with same name if any
      if category
        self.category = project.issue_categories.find_by_name(category.name)
      end

      # Clear the assignee if not available in the new project for new issues (eg. copy)
      # For existing issue, the previous assignee is still valid, so we keep it
      if new_record? && assigned_to && !assignable_users.include?(assigned_to)
        self.assigned_to_id = nil
      end

      reassign_custom_field_values
    end

    self.project
  end

  def description=(arg)
    if arg.is_a?(String)
      arg = arg.gsub(/(\r\n|\n|\r)/, "\r\n")
    end
    write_attribute(:description, arg)
  end

  # Overrides assign_attributes so that project get assigned first
  def assign_attributes(new_attributes, *args)
    return if new_attributes.nil?
    attrs = new_attributes.dup
    attrs.stringify_keys!

    %w(project project_id).each do |attr|
      if attrs.has_key?(attr)
        send "#{attr}=", attrs.delete(attr)
      end
    end
    super attrs, *args
  end

  def attributes=(new_attributes)
    assign_attributes new_attributes
  end

  safe_attributes 'project_id',
                  'category_id',
                  'assigned_to_id',
                  'priority_id',
                  'subject',
                  'description',
                  'custom_field_values',
                  'notes',
                  :if => lambda {|issue, user| issue.new_record? || issue.attributes_editable?(user) }

  safe_attributes 'repository_id',
                  'commit_base',
                  'commit_compare',
                  :if => lambda {|pull, user| pull.new_record? }

  safe_attributes 'notes',
                  :if => lambda {|issue, user| issue.notes_addable?(user)}

  safe_attributes 'private_notes',
                  :if => lambda {|issue, user| !issue.new_record? && user.allowed_to?(:set_notes_private, issue.project)}

  safe_attributes 'watcher_user_ids',
                  :if => lambda {|pull, user| pull.new_record? && user.allowed_to?(:add_pull_watchers, pull.project)}

  def init_journal(user, notes = "")
    @current_journal ||= Journal.new(:journalized => self, :user => user, :notes => notes)
  end

  # Returns the current journal or nil if it's not initialized
  def current_journal
    @current_journal
  end

  # Clears the current journal
  def clear_journal
    @current_journal = nil
  end

  # Returns the names of attributes that are journalized when updating the issue
  def journalized_attribute_names
    Pull.column_names - %w(id created_on updated_on merged_on closed_on)
  end

  # Returns the id of the last journal or nil
  def last_journal_id
    if new_record?
      nil
    else
      journals.maximum(:id)
    end
  end

  # Returns a scope for journals that have an id greater than journal_id
  def journals_after(journal_id)
    scope = journals.reorder("#{Journal.table_name}.id ASC")
    if journal_id.present?
      scope = scope.where("#{Journal.table_name}.id > ?", journal_id.to_i)
    end
    scope
  end

  # Returns the journals that are visible to user with their index
  # Used to display the issue history
  def visible_journals_with_index(user=User.current)
    result = journals.
      preload(:details).
      preload(:user => :email_address).
      reorder(:created_on, :id).to_a

    result.each_with_index {|j,i| j.indice = i+1}

    unless user.allowed_to?(:view_private_notes, project)
      result.select! do |journal|
        !journal.private_notes? || journal.user == user
      end
    end
    Journal.preload_journals_details_custom_fields(result)
    result.select! {|journal| journal.notes? || journal.visible_details.any?}
    result
  end

  # Return true if the issue is closed, otherwise false
  def closed?
    closed_on.present?
  end

  # Return true if the issue is being closed
  def closing?
    if new_record?
      closed?
    else
      closed_on_changed? && closed?
    end
  end

  # Users the pull request can be assigned to
  def assignable_users
    users = project.assignable_users.to_a
    users << author if author && author.active?
    if assigned_to_id_was.present? && assignee = Principal.find_by_id(assigned_to_id_was)
      users << assignee
    end
    users.uniq.sort
  end

  # Returns the previous assignee (user or group) if changed
  def assigned_to_was
    # assigned_to_id_was is reset before after_save callbacks
    user_id = @previous_assigned_to_id || assigned_to_id_was
    if user_id && user_id != assigned_to_id
      @assigned_to_was ||= Principal.find_by_id(user_id)
    end
  end

  # Returns the users that should be notified
  def notified_users
    notified = []
    # Author and assignee are always notified unless they have been
    # locked or don't want to be notified
    notified << author if author
    if assigned_to
      notified += (assigned_to.is_a?(Group) ? assigned_to.users : [assigned_to])
    end
    if assigned_to_was
      notified += (assigned_to_was.is_a?(Group) ? assigned_to_was.users : [assigned_to_was])
    end
    notified = notified.select {|u| u.active? && u.notify_about?(self)}

    notified += project.notified_users
    notified.uniq!
    notified
  end

  # Returns the email addresses that should be notified
  def recipients
    notified_users.collect(&:mail)
  end

  def each_notification(users, &block)
    #if users.any?
    #  yield(users)
    #end
  end

  def notify?
    false # @notify != false
  end

  def notify=(arg)
    @notify = arg
  end

  def commit_between
    commit_base + ".." + commit_compare
  end

  # Returns a string of css classes that apply to the issue
  def css_classes(user=User.current)
    s = "pull #{priority.try(:css_classes)}"
    #s << ' closed' if closed?
    if user.logged?
      s << ' created-by-me' if author_id == user.id
      s << ' assigned-to-me' if assigned_to_id == user.id
      s << ' assigned-to-my-group' if user.groups.any? {|g| g.id == assigned_to_id}
    end
    s
  end

  private

  def user_permission?(user, permission)
    if project && !project.active?
      perm = Redmine::AccessControl.permission(permission)
      return false unless perm && perm.read?
    end

    user.allowed_to?(permission, project)
  end

  # Make sure updated_on is updated when adding a note and set updated_on now
  # so we can set closed_on with the same value on closing
  def force_updated_on_change
    if @current_journal || changed?
      self.updated_on = current_time_from_proper_timezone
      if new_record?
        self.created_on = updated_on
      end
    end
  end

  # Callback for setting closed_on when the issue is closed.
  # The closed_on attribute stores the time of the last closing
  # and is preserved when the issue is reopened.
  def update_closed_on
    if closing?
      self.closed_on = updated_on
    end
  end

  # Saves the changes in a Journal
  # Called after_save
  def create_journal
    if current_journal
      current_journal.save
    end
  end

  def send_notification
    if notify? && Setting.notified_events.include?('pull_added')
      Mailer.deliver_pull_add(self)
    end
  end

  # Stores the previous assignee so we can still have access
  # to it during after_save callbacks (assigned_to_id_was is reset)
  def set_assigned_to_was
    @previous_assigned_to_id = assigned_to_id_was
  end

  # Clears the previous assignee at the end of after_save callbacks
  def clear_assigned_to_was
    @assigned_to_was = nil
    @previous_assigned_to_id = nil
  end
end
