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

            # Show key changes and comments
            fields = []
            
            # Add due date change
            due_date_detail = current_journal.details.find { |d| d.prop_key == 'due_date' }
            if due_date_detail
              old_date = due_date_detail.old_value.present? ? format_date(due_date_detail.old_value) : "未設定"
              new_date = due_date_detail.value.present? ? format_date(due_date_detail.value) : "未設定"
              fields << { title: "期日",
                          value: "#{old_date} → #{new_date}",
                          short: true }
            end
            
            # Add assigned_to change
            assigned_detail = current_journal.details.find { |d| d.prop_key == 'assigned_to_id' }
            if assigned_detail
              old_user = assigned_detail.old_value.present? ? Principal.find_by(id: assigned_detail.old_value)&.name : "未設定"
              new_user = assigned_detail.value.present? ? Principal.find_by(id: assigned_detail.value)&.name : "未設定"
              fields << { title: "担当者",
                          value: "#{old_user} → #{new_user}",
                          short: true }
            end
            
            # Add progress if changed
            progress_detail = current_journal.details.find { |d| d.prop_key == 'done_ratio' }
            if progress_detail
              old_progress = progress_detail.old_value.present? ? "#{progress_detail.old_value}%" : "0%"
              new_progress = progress_detail.value.present? ? "#{progress_detail.value}%" : "0%"
              fields << { title: "進捗率",
                          value: "#{old_progress} → #{new_progress}",
                          short: true }
            end
            
            # Add status change
            status_detail = current_journal.details.find { |d| d.prop_key == 'status_id' }
            if status_detail
              old_status = status_detail.old_value.present? ? IssueStatus.find_by(id: status_detail.old_value)&.name : "未設定"
              new_status = status_detail.value.present? ? IssueStatus.find_by(id: status_detail.value)&.name : "未設定"
              fields << { title: "ステータス",
                          value: "#{old_status} → #{new_status}",
                          short: true }
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

        def format_date(date_str)
          return date_str unless date_str.present?
          begin
            Date.parse(date_str).strftime("%Y/%m/%d")
          rescue
            date_str
          end
        end

        def messenger_to_be_notified
          to_be_notified = (notified_users + notified_watchers).compact
          to_be_notified.uniq
        end

        def build_mentions_message
          mentions = []
          
          # Check if assignee was changed in this update
          assignee_detail = current_journal&.details&.find { |d| d.prop_key == 'assigned_to_id' }
          
          if assignee_detail
            # Assignee was changed - mention both old and new assignees
            assignee_mentions = []
            
            # Add old assignee mention
            if assignee_detail.old_value.present?
              old_assignee = Principal.find_by(id: assignee_detail.old_value)
              if old_assignee
                old_mention = Messenger.format_user_mention(old_assignee)
                assignee_mentions << old_mention if old_mention.present?
              end
            end
            
            # Add new assignee mention
            if assignee_detail.value.present?
              new_assignee = Principal.find_by(id: assignee_detail.value)
              if new_assignee
                new_mention = Messenger.format_user_mention(new_assignee)
                assignee_mentions << new_mention if new_mention.present?
              end
            end
            
            if assignee_mentions.any?
              mentions << "\n\n👤 担当者: #{assignee_mentions.join(' ')}"
            end
          elsif assigned_to.present?
            # No assignee change - just show current assignee
            assignee_mention = Messenger.format_user_mention(assigned_to)
            mentions << "\n\n👤 担当者: #{assignee_mention}" if assignee_mention.present?
          end
          
          # Add watcher mentions with proper label
          if watcher_users.any?
            watcher_mentions = watcher_users.map { |user| Messenger.format_user_mention(user) }.compact
            if watcher_mentions.any?
              mentions << "\n👁️ ウォッチャー: #{watcher_mentions.join(' ')}"
            end
          end
          
          mentions.join
        end
      end
    end
  end
end
