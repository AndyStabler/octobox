class AppInstallation < ApplicationRecord
  has_many :repositories, dependent: :destroy
  has_many :app_installation_permissions, dependent: :delete_all
  has_many :users, through: :app_installation_permissions
  has_one :subscription_purchase, foreign_key: :account_id, primary_key: :account_id

  validates :github_id, presence: true, uniqueness: true
  validates :account_login, presence: true
  validates :account_id, presence: true

  def add_repositories(remote_repositories)
    remote_repositories.each do |remote_repository|
      repository = Repository.find_or_create_by(github_id: remote_repository['id'])

      repository.update_attributes({
        full_name: remote_repository['full_name'],
        private: remote_repository['private'],
        owner: remote_repository['full_name'].split('/').first,
        github_id: remote_repository['id'],
        last_synced_at: Time.current,
        app_installation_id: self.id
      })

      repository.notifications.includes(:user).find_each{|n| n.update_subject(true) }
    end
  end

  def remove_repositories(remote_repositories)
    remote_repositories.each do |remote_repository|
      repository = repositories.find_by_github_id(remote_repository['id'])
      next unless repository.present?
      repository.subjects.each(&:destroy)
      repository.destroy
    end
  end

  def settings_url
    org_segment = account_type == 'Organization' ? "/organizations/#{account_login}" : ''
    "#{Octobox.config.github_domain}#{org_segment}/settings/installations/#{github_id}"
  end

  def github_avatar_url
    "#{Octobox.config.github_domain}/#{account_login}.png"
  end

  def private_repositories_enabled?
    return true unless Octobox.octobox_io?
    subscription_purchase.try(:private_repositories_enabled?)
  end

  def sync
    remote_installation = Octobox.github_app_client.installation(github_id, accept: 'application/vnd.github.machine-man-preview+json')
    update_attributes(AppInstallation.map_from_api(remote_installation))
  end

  def sync_repositories
    access_token = Octobox.github_app_client.create_installation_access_token(self.github_id, accept: 'application/vnd.github.machine-man-preview+json')
    client = Octokit::Client.new(access_token: access_token.token, auto_paginate: true)
    remote_repositories = client.list_app_installation_repositories.repositories
    add_repositories(remote_repositories)
  end

  def self.map_from_api(remote_installation)
    {
      github_id: remote_installation['id'],
      app_id: remote_installation['app_id'],
      account_login: remote_installation['account']['login'],
      account_id: remote_installation['account']['id'],
      account_type: remote_installation['account']['type'],
      target_type: remote_installation['target_type'],
      target_id: remote_installation['target_id'],
      permission_pull_requests: remote_installation['permissions']['pull_requests'],
      permission_issues: remote_installation['permissions']['issues'],
      permission_statuses: remote_installation['permissions']['statuses']
    }
  end
end
