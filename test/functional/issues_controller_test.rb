require File.expand_path('../../test_helper', __FILE__)

class IssuesControllerTest < ActionController::TestCase
  fixtures :projects,
           :users, :email_addresses, :user_preferences,
           :roles,
           :members,
           :member_roles,
           :issues,
           :issue_statuses,
           :issue_relations,
           :versions,
           :trackers,
           :projects_trackers,
           :issue_categories,
           :enabled_modules,
           :enumerations,
           :attachments,
           :workflows,
           :custom_fields,
           :custom_values,
           :custom_fields_projects,
           :custom_fields_trackers,
           :time_entries,
           :journals,
           :journal_details,
           :queries,
           :repositories,
           :changesets,
           :issues,
           :pulls,
           :pull_issues

  def setup
    @project = Project.find(1)
    EnabledModule.create(:project => @project, :name => 'pulls')
    @request.session[:user_id] = 1
  end

  def test_get_show_with_related_pull
    get :show, :id => 1

    assert_response :success
    assert_select '#pull_relations a', :text => /PR#1/
  end

  def test_get_show_without_related_pull
    get :show, :id => 2

    assert_response :success
    assert_select '#pull_relations', 0
  end
end
