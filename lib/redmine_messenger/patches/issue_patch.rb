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
            
            # Show all relevant fields for new issues
            attachment[:fields] = []
            
            # Add start date
            if start_date.present?
              attachment[:fields] << { title: "開始日",
                                       value: format_date(start_date.to_s),
                                       short: true }
            end
            
            # Add due date
            if due_date.present?
              attachment[:fields] << { title: "期日",
                                       value: format_date(due_date.to_s),
                                       short: true }
            end
            
            # Add estimated hours
            if estimated_hours.present?
              attachment[:fields] << { title: "予定工数",
                                       value: format_hours_hm(estimated_hours),
                                       short: true }
            end
            
            # Add status
            if status.present?
              attachment[:fields] << { title: "ステータス",
                                       value: status.name,
                                       short: true }
            end
            
            # Add priority
            if priority.present?
              attachment[:fields] << { title: "優先度",
                                       value: priority.name,
                                       short: true }
            end
            
            # Add category
            if category.present?
              attachment[:fields] << { title: "カテゴリ",
                                       value: category.name,
                                       short: true }
            end
            
            # Add fixed version
            if fixed_version.present?
              attachment[:fields] << { title: "対象バージョン",
                                       value: fixed_version.name,
                                       short: true }
            end
            
            # Add progress if greater than 0
            if done_ratio > 0
              attachment[:fields] << { title: "進捗率",
                                       value: "#{done_ratio}%",
                                       short: true }
            end
            
            # Add custom fields
            custom_field_values.each do |custom_value|
              next unless custom_value.value.present?
              
              formatted_value = format_custom_field_value(custom_value.value, custom_value.custom_field)
              next if formatted_value == "未設定"
              
              attachment[:fields] << { title: custom_value.custom_field.name,
                                       value: formatted_value,
                                       short: true }
            end

            # Add attachments
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
          
          # Skip update notification if this is triggered by a new issue creation
          # When an issue is created, the id is present in previous_changes
          return if previous_changes.key?('id')

          # Check if this is a child issue being added to a parent
          if handle_child_issue_addition
            return
          end

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
            
            # Process all field changes
            current_journal.details.each do |detail|
              field_info = format_field_change(detail)
              fields << field_info if field_info
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

        def handle_child_issue_addition
          # Check if this issue just got a parent assigned (child issue creation/update)
          parent_detail = current_journal.details.find { |d| d.prop_key == 'parent_id' }
          return false unless parent_detail && parent_detail.old_value.blank? && parent_detail.value.present?

          # Find the parent issue
          parent_issue = Issue.find_by(id: parent_detail.value)
          return false unless parent_issue

          # Send notification to parent issue's project channels
          channels = Messenger.channels_for_project parent_issue.project
          url = Messenger.url_for_project parent_issue.project

          if Messenger.setting_for_project parent_issue.project, :messenger_direct_users_messages
            parent_issue.messenger_to_be_notified.each do |user|
              channels.append "@#{user.login}" unless user == current_journal.user
            end
          end

          return false unless channels.present? && url && Messenger.setting_for_project(parent_issue.project, :post_updates)
          return false if parent_issue.is_private? && !Messenger.setting_for_project(parent_issue.project, :post_private_issues)

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            parent_url = "<#{Messenger.object_url parent_issue}|##{parent_issue.id} #{Messenger.markup_format parent_issue.subject}>"
            child_url = "<#{Messenger.object_url self}|##{id} #{Messenger.markup_format subject}>"
            
            main_message = "#{Messenger.markup_format(parent_issue.project.name)} - 親チケット #{parent_url} に 子チケット #{child_url} が #{Messenger.markup_format(current_journal.user.to_s)} によって追加されました。"
            
            # Add mentions for parent issue
            parent_mentions = ""
            if parent_issue.assigned_to.present?
              assignee_mention = Messenger.format_user_mention(parent_issue.assigned_to, parent_issue.project)
              parent_mentions << "\n\n👤 担当者: #{assignee_mention}" if assignee_mention.present?
            end
            
            if parent_issue.watcher_users.any?
              watcher_mentions = parent_issue.watcher_users.map { |user| Messenger.format_user_mention(user, parent_issue.project) }.compact
              if watcher_mentions.any?
                parent_mentions << "\n👁️ ウォッチャー: #{watcher_mentions.join(' ')}"
              end
            end
            
            full_message = "#{main_message}#{parent_mentions}"
            
            Messenger.speak full_message, channels, url, attachment: {}, project: parent_issue.project
          ensure
            ::I18n.locale = initial_language
          end
          
          true
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

        def format_hours_hm(hours_decimal)
          return "0:00" if hours_decimal.blank? || hours_decimal == 0
          
          total_minutes = (hours_decimal * 60).round
          hours_part = total_minutes / 60
          minutes_part = total_minutes % 60
          
          "#{hours_part}:#{minutes_part.to_s.rjust(2, '0')}"
        end

        def format_field_change(detail)
          return nil if detail.blank?
          
          case detail.property
          when 'attr'
            format_attribute_change(detail)
          when 'cf'
            format_custom_field_change(detail)
          else
            nil
          end
        end

        def format_attribute_change(detail)
          case detail.prop_key
          when 'due_date'
            old_date = detail.old_value.present? ? format_date(detail.old_value) : "未設定"
            new_date = detail.value.present? ? format_date(detail.value) : "未設定"
            { title: "期日", value: "#{old_date} → #{new_date}", short: true }
            
          when 'start_date'
            old_date = detail.old_value.present? ? format_date(detail.old_value) : "未設定"
            new_date = detail.value.present? ? format_date(detail.value) : "未設定"
            { title: "開始日", value: "#{old_date} → #{new_date}", short: true }
            
          when 'estimated_hours'
            old_hours = detail.old_value.present? ? format_hours_hm(detail.old_value.to_f) : "未設定"
            new_hours = detail.value.present? ? format_hours_hm(detail.value.to_f) : "未設定"
            { title: "予定工数", value: "#{old_hours} → #{new_hours}", short: true }
            
          when 'assigned_to_id'
            old_user = detail.old_value.present? ? Principal.find_by(id: detail.old_value)&.name : "未設定"
            new_user = detail.value.present? ? Principal.find_by(id: detail.value)&.name : "未設定"
            { title: "担当者", value: "#{old_user} → #{new_user}", short: true }
            
          when 'done_ratio'
            old_progress = detail.old_value.present? ? "#{detail.old_value}%" : "0%"
            new_progress = detail.value.present? ? "#{detail.value}%" : "0%"
            { title: "進捗率", value: "#{old_progress} → #{new_progress}", short: true }
            
          when 'status_id'
            old_status = detail.old_value.present? ? IssueStatus.find_by(id: detail.old_value)&.name : "未設定"
            new_status = detail.value.present? ? IssueStatus.find_by(id: detail.value)&.name : "未設定"
            { title: "ステータス", value: "#{old_status} → #{new_status}", short: true }
            
          when 'priority_id'
            old_priority = detail.old_value.present? ? IssuePriority.find_by(id: detail.old_value)&.name : "未設定"
            new_priority = detail.value.present? ? IssuePriority.find_by(id: detail.value)&.name : "未設定"
            { title: "優先度", value: "#{old_priority} → #{new_priority}", short: true }
            
          when 'category_id'
            old_category = detail.old_value.present? ? IssueCategory.find_by(id: detail.old_value)&.name : "未設定"
            new_category = detail.value.present? ? IssueCategory.find_by(id: detail.value)&.name : "未設定"
            { title: "カテゴリ", value: "#{old_category} → #{new_category}", short: true }
            
          when 'fixed_version_id'
            old_version = detail.old_value.present? ? Version.find_by(id: detail.old_value)&.name : "未設定"
            new_version = detail.value.present? ? Version.find_by(id: detail.value)&.name : "未設定"
            { title: "対象バージョン", value: "#{old_version} → #{new_version}", short: true }
            
          when 'subject'
            old_subject = detail.old_value.present? ? detail.old_value : "未設定"
            new_subject = detail.value.present? ? detail.value : "未設定"
            { title: "題名", value: "#{old_subject} → #{new_subject}", short: false }
            
          when 'description'
            # Skip description changes as they're usually too long
            nil
            
          else
            nil
          end
        end

        def format_custom_field_change(detail)
          custom_field = CustomField.find_by(id: detail.prop_key)
          return nil unless custom_field
          
          old_value = format_custom_field_value(detail.old_value, custom_field)
          new_value = format_custom_field_value(detail.value, custom_field)
          
          { title: custom_field.name, value: "#{old_value} → #{new_value}", short: true }
        end

        def format_custom_field_value(value, custom_field)
          return "未設定" if value.blank?
          
          case custom_field.field_format
          when 'bool'
            value == '1' ? 'Yes' : 'No'
          when 'date'
            begin
              Date.parse(value).strftime("%Y/%m/%d")
            rescue
              value
            end
          when 'float', 'int'
            value.to_s
          when 'list'
            # For list custom fields, show the actual option value
            custom_option = custom_field.custom_options.find_by(value: value)
            custom_option ? custom_option.value : value
          when 'user'
            # For user custom fields
            user = Principal.find_by(id: value)
            user ? user.name : value
          when 'version'
            # For version custom fields
            version = Version.find_by(id: value)
            version ? version.name : value
          when 'link'
            # For link custom fields, show as-is
            value
          when 'text', 'string'
            # For text and string, limit length for display
            value.length > 50 ? "#{value[0..47]}..." : value
          else
            # Default case for any other format
            value
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
                old_mention = Messenger.format_user_mention(old_assignee, project)
                assignee_mentions << old_mention if old_mention.present?
              end
            end
            
            # Add new assignee mention
            if assignee_detail.value.present?
              new_assignee = Principal.find_by(id: assignee_detail.value)
              if new_assignee
                new_mention = Messenger.format_user_mention(new_assignee, project)
                assignee_mentions << new_mention if new_mention.present?
              end
            end
            
            if assignee_mentions.any?
              mentions << "\n\n👤 担当者: #{assignee_mentions.join(' ')}"
            end
          elsif assigned_to.present?
            # No assignee change - just show current assignee
            assignee_mention = Messenger.format_user_mention(assigned_to, project)
            mentions << "\n\n👤 担当者: #{assignee_mention}" if assignee_mention.present?
          end
          
          # Add watcher mentions with proper label
          if watcher_users.any?
            watcher_mentions = watcher_users.map { |user| Messenger.format_user_mention(user, project) }.compact
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
