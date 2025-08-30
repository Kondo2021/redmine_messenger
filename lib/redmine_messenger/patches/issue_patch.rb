# frozen_string_literal: true

module RedmineMessenger
  module Patches
    module IssuePatch
      extend ActiveSupport::Concern

      included do
        include InstanceMethods

        after_create_commit :send_messenger_create
        after_update_commit :send_messenger_update
      end

      module InstanceMethods
        def send_messenger_create
          channels = Messenger.channels_for_project project
          url = Messenger.url_for_project project

          if Messenger.setting_for_project project, :messenger_direct_users_messages
            messenger_to_be_notified.each do |user|
              channels.append "@#{user.login}" unless user == author
            end
          end

          return unless channels.present? && url
          return if is_private? && !Messenger.setting_for_project(project, :post_private_issues)

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            attachment = {}
            if description.present? && Messenger.setting_for_project(project, :new_include_description)
              attachment[:text] = Messenger.markup_format description
            end
            # Show only essential fields
            attachment[:fields] = []
            
            if done_ratio > 0
              attachment[:fields] << { title: "進捗率",
                                       value: "#{done_ratio}%",
                                       short: false }
            end

            attachments.each do |att|
              attachment[:fields] << { title: I18n.t(:label_attachment),
                                       value: "<#{Messenger.object_url att}|#{ERB::Util.html_escape att.filename}>",
                                       short: true }
            end


            main_message = l(:label_messenger_issue_created,
                              project_name: Messenger.markup_format(project.name),
                              tracker: tracker.name,
                              url: "<#{Messenger.object_url self}|#{Messenger.markup_format subject}>",
                              user: Messenger.markup_format(author.to_s))
            
            # Add mentions on separate lines
            mentions = build_mentions_message
            full_message = "#{main_message}#{mentions}"
            
            Messenger.speak full_message, channels, url, attachment: attachment, project: project
          ensure
            ::I18n.locale = initial_language
          end
        end

        def send_messenger_update
          return if current_journal.nil?

          channels = Messenger.channels_for_project project
          url = Messenger.url_for_project project

          if Messenger.setting_for_project project, :messenger_direct_users_messages
            messenger_to_be_notified.each do |user|
              channels.append "@#{user.login}" unless user == current_journal.user
            end
          end

          return unless channels.present? && url && Messenger.setting_for_project(project, :post_updates)
          return if is_private? && !Messenger.setting_for_project(project, :post_private_issues)
          return if current_journal.private_notes? && !Messenger.setting_for_project(project, :post_private_notes)

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            attachment = {}
            if Messenger.setting_for_project project, :updated_include_description
              attachment_text = Messenger.attachment_text_from_journal current_journal
              attachment[:text] = attachment_text if attachment_text.present?
            end

            # Show only key changes and comments
            fields = []
            
            # Add progress if changed
            progress_detail = current_journal.details.find { |d| d.prop_key == 'done_ratio' }
            if progress_detail && progress_detail.value.present?
              fields << { title: "進捗率",
                          value: "#{progress_detail.value}%",
                          short: false }
            end
            
            # Add status change
            status_detail = current_journal.details.find { |d| d.prop_key == 'status_id' }
            if status_detail && status_detail.value.present?
              status_obj = IssueStatus.find_by(id: status_detail.value)
              if status_obj
                fields << { title: "ステータス",
                            value: Messenger.markup_format(status_obj.name),
                            short: true }
              end
            end
            
            # Add comments
            if current_journal.notes.present?
              fields << { title: "コメント",
                          value: Messenger.markup_format(current_journal.notes),
                          short: false }
            end
            
            fields << { title: I18n.t(:field_is_private), short: true } if current_journal.private_notes?
            attachment[:fields] = fields if fields.any?

            main_message = l(:label_messenger_issue_updated,
                              project_name: Messenger.markup_format(project.name),
                              tracker: tracker.name,
                              url: "<#{Messenger.object_url self}#change-#{current_journal.id}|#{Messenger.markup_format subject}>",
                              user: Messenger.markup_format(current_journal.user.to_s))
            
            # Add mentions on separate lines
            mentions = build_mentions_message
            full_message = "#{main_message}#{mentions}"
            
            Messenger.speak full_message, channels, url, attachment: attachment, project: project
          ensure
            ::I18n.locale = initial_language
          end
        end

        private

        def messenger_to_be_notified
          to_be_notified = (notified_users + notified_watchers).compact
          to_be_notified.uniq
        end

        def build_mentions_message
          mentions = []
          
          # Add assignee mention
          if assigned_to.present?
            assignee_mention = Messenger.format_user_mention(assigned_to)
            mentions << "\n\n担当者: #{assignee_mention}" if assignee_mention.present?
          end
          
          # Add watcher mentions
          if watcher_users.any?
            watcher_mentions = watcher_users.map { |user| Messenger.format_user_mention(user) }.compact
            if watcher_mentions.any?
              mentions << "\nウォッチャー: #{watcher_mentions.join(' ')}\n\n"
            end
          end
          
          mentions.join
        end
      end
    end
  end
end
