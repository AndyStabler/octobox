# frozen_string_literal: true
class Notification < ApplicationRecord

  include Octobox::Notifications::InclusiveScope
  include Octobox::Notifications::ExclusiveScope
  include Octobox::Notifications::SyncSubject
  include Octobox::Notifications::SyncRepository

  SUBJECTABLE_TYPES = SUBJECT_TYPE_COMMIT_RELEASE + SUBJECT_TYPE_ISSUE_REQUEST.values

  if DatabaseConfig.is_postgres?
    include PgSearch
    pg_search_scope :search_by_subject_title,
                    against: :subject_title,
                    order_within_rank: 'notifications.updated_at DESC',
                    using: {
                      tsearch: {
                        prefix: true,
                        negation: true,
                        dictionary: "english"
                      }
                    }
  else
    def self.search_by_subject_title(title)
      where('subject_title like ?', "%#{title}%")
    end
  end

  belongs_to :user
  belongs_to :subject, foreign_key: :subject_url, primary_key: :url, optional: true
  belongs_to :repository, foreign_key: :repository_full_name, primary_key: :full_name, optional: true
  has_many :labels, through: :subject

  validates :subject_url, presence: true
  validates :archived, inclusion: [true, false]

  paginates_per 20

  class << self
    def attributes_from_api_response(api_response)
      attrs = DownloadService::API_ATTRIBUTE_MAP.map do |attr, path|
        value = api_response.to_h.dig(*path)
        value.delete!("\u0000") if value.is_a?(String)
        [attr, value]
      end.to_h
      if "RepositoryInvitation" == api_response.subject.type
        attrs[:subject_url] = "#{api_response.repository.html_url}/invitations"
      end
      attrs[:updated_at] = Time.current if api_response.updated_at.nil?
      attrs
    end
  end

  def state
    return unless display_subject?
    subject.try(:state)
  end

  def self.archive(notifications, value)
    value = value ? ActiveRecord::Type::Boolean.new.cast(value) : true
    notifications.update_all(archived: value)
    mark_read(notifications)
  end

  def self.mark_read(notifications)
    unread = notifications.select(&:unread)
    return if unread.empty?
    user = unread.first.user
    MarkReadWorker.perform_async_if_configured(user.id, unread.map(&:github_id))
    where(id: unread.map(&:id)).update_all(unread: false)
  end

  def self.mark_read_on_github(user, notification_ids)
    conn = user.github_client.client_without_redirects
    manager = Typhoeus::Hydra.new(max_concurrency: Octobox.config.max_concurrency)
    begin
      conn.in_parallel(manager) do
        notification_ids.each do |id|
            conn.patch "notifications/threads/#{id}"
        end
      end
    rescue Octokit::Forbidden, Octokit::NotFound
      # one or more notifications are for repos the user no longer has access to
    end
  end

  def self.mute(notifications)
    return if notifications.empty?
    user = notifications.to_a.first.user
    MuteNotificationsWorker.perform_async_if_configured(user.id, notifications.map(&:github_id))
    where(id: notifications.map(&:id)).update_all(archived: true, unread: false, muted_at: Time.current)
  end

  def self.mute_on_github(user, notification_ids)
    conn = user.github_client.client_without_redirects
    manager = Typhoeus::Hydra.new(max_concurrency: Octobox.config.max_concurrency)
    begin
      conn.in_parallel(manager) do
        notification_ids.each do |id|
          conn.patch "notifications/threads/#{id}"
          conn.put "notifications/threads/#{id}/subscription", {ignored: true}.to_json
        end
      end
    rescue Octokit::Forbidden, Octokit::NotFound
      # one or more notifications are for repos the user no longer has access to
    end
  end

  def expanded_subject_url
    return subject_url unless display_subject?
    subject.try(:html_url) || subject_url # Use the sync'd HTML URL if possible, else the API one
  end

  def web_url
    Octobox::SubjectUrlParser.new(expanded_subject_url, latest_comment_url: latest_comment_url)
      .to_html_url
  end

  def repo_url
    "#{Octobox.config.github_domain}/#{repository_full_name}"
  end

  def unarchive_if_updated
    return unless self.archived?
    change = changes['updated_at']
    return unless change
    if self.archived && change[1] > change[0]
      self.archived = false
    end
  end

  def update_from_api_response(api_response, unarchive: false)
    attrs = Notification.attributes_from_api_response(api_response)
    self.attributes = attrs
    self.archived = false if archived.nil? # fixup existing records where archived is nil
    unarchive_if_updated if unarchive
    save(touch: false) if changed?
    update_subject
    update_repository
  end

  def github_app_installed?
    Octobox.github_app? && user.github_app_authorized? && repository.try(:display_subject?)
  end

  def subjectable?
    SUBJECTABLE_TYPES.include?(subject_type)
  end

  def display_subject?
    @display_subject ||= subjectable? && (Octobox.fetch_subject? || github_app_installed?)
  end

  def upgrade_required?
    return nil unless repository.present?
    repository.private? && !repository.required_plan_available?
  end
end
