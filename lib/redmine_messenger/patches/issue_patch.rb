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
            
            # Also send parent notification if this is a child issue
            send_parent_notification_if_child
          ensure
            ::I18n.locale = initial_language
          end
        end

        def send_messenger_update
          return if current_journal.nil?
          
          # Check if this is a child issue being added to a parent first
          if handle_child_issue_addition
            return
          end
          
          # Check if this is related issue addition  
          if handle_relation_addition
            return
          end
          
          # Check if this is a parent issue being updated due to child addition
          if handle_parent_issue_update
            return
          end
          
          # Skip update notification if this is triggered by a new issue creation
          # When an issue is created, the id is present in previous_changes
          return if previous_changes.key?('id')

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
            
            # Collect field changes for update history
            field_changes = []
            current_journal.details.each do |detail|
              field_info = format_field_change(detail)
              if field_info
                field_changes << "#{field_info[:title]}: #{field_info[:value]}"
              end
            end
            
            # Add update history if there are field changes
            if field_changes.any?
              fields << { title: "更新履歴",
                          value: field_changes.join("\n"),
                          short: false }
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
            
            # Only add mentions if there are actual field changes or comments
            mentions = ""
            if fields.any? || current_journal.notes.present?
              mentions = build_mentions_message
            end
            
            full_message = "#{main_message}#{mentions}"
            
            Messenger.speak full_message, channels, url, attachment: attachment, project: project
          ensure
            ::I18n.locale = initial_language
          end
        end

        def handle_child_issue_addition
          # Debug: log journal details
          Rails.logger.info "MESSENGER DEBUG: Checking child issue addition for issue ##{id}"
          Rails.logger.info "MESSENGER DEBUG: Journal details: #{current_journal.details.map { |d| "#{d.prop_key}: #{d.old_value} -> #{d.value}" }.join(', ')}"
          
          # Check if this issue just got a parent assigned (child issue creation/update)
          parent_detail = current_journal.details.find { |d| d.prop_key == 'parent_id' }
          unless parent_detail
            Rails.logger.info "MESSENGER DEBUG: No parent_id detail found"
            return false
          end
          
          Rails.logger.info "MESSENGER DEBUG: Parent detail - old: '#{parent_detail.old_value}', new: '#{parent_detail.value}'"
          
          # Check if parent was just assigned (old value blank/nil, new value present)
          unless (parent_detail.old_value.blank? || parent_detail.old_value.nil?) && parent_detail.value.present?
            Rails.logger.info "MESSENGER DEBUG: Not a new parent assignment"
            return false
          end

          # Find the parent issue
          parent_issue = Issue.find_by(id: parent_detail.value)
          unless parent_issue
            Rails.logger.info "MESSENGER DEBUG: Parent issue not found: #{parent_detail.value}"
            return false
          end

          Rails.logger.info "MESSENGER DEBUG: Found parent issue ##{parent_issue.id}: #{parent_issue.subject}"

          # Send notification to parent issue's project channels
          channels = Messenger.channels_for_project parent_issue.project
          url = Messenger.url_for_project parent_issue.project

          if Messenger.setting_for_project parent_issue.project, :messenger_direct_users_messages
            parent_to_be_notified = (parent_issue.notified_users + parent_issue.notified_watchers).compact.uniq
            parent_to_be_notified.each do |user|
              channels.append "@#{user.login}" unless user == current_journal.user
            end
          end

          return false unless channels.present? && url && Messenger.setting_for_project(parent_issue.project, :post_updates)
          return false if parent_issue.is_private? && !Messenger.setting_for_project(parent_issue.project, :post_private_issues)

          Rails.logger.info "MESSENGER DEBUG: Sending child addition notification"

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            parent_url = "<#{Messenger.object_url parent_issue}|#{Messenger.markup_format parent_issue.subject}>"
            child_url = "<#{Messenger.object_url self}|#{Messenger.markup_format subject}>"
            
            main_message = "#{Messenger.markup_format(parent_issue.project.name)} - 親チケット #{parent_url} に 子チケット #{child_url} が #{Messenger.markup_format(current_journal.user.to_s)} によって追加されました。"
            
            # Add mentions for parent issue (only these two items)
            parent_mentions = []
            if parent_issue.assigned_to.present?
              assignee_mention = Messenger.format_user_mention(parent_issue.assigned_to, parent_issue.project)
              parent_mentions << "\n\n👤 担当者: #{assignee_mention}" if assignee_mention.present?
            end
            
            if parent_issue.watcher_users.any?
              watcher_mentions = []
              parent_issue.watcher_users.each do |user|
                mention = Messenger.format_user_mention(user, parent_issue.project)
                watcher_mentions << mention if mention.present?
              end
              
              if watcher_mentions.any?
                parent_mentions << "\n👁️ ウォッチャー: #{watcher_mentions.uniq.join(' ')}"
              end
            end
            
            full_message = "#{main_message}#{parent_mentions.join}"
            
            Rails.logger.info "MESSENGER DEBUG: Final message: #{full_message}"
            
            # Create attachment with child ticket info in embed format
            attachment = {
              fields: [
                {
                  name: "子チケット",
                  value: "##{id} #{subject}",
                  short: true
                }
              ]
            }
            
            Messenger.speak full_message, channels, url, attachment: attachment, project: parent_issue.project
          ensure
            ::I18n.locale = initial_language
          end
          
          Rails.logger.info "MESSENGER DEBUG: Child addition notification sent successfully"
          true
        end

        def handle_parent_issue_update
          # まず子チケットがあるかチェック
          has_children = children.any?
          unless has_children
            Rails.logger.info "【Discord通知】子チケットなし - 親チケット更新チェックをスキップ"
            return false
          end
          
          Rails.logger.info "【Discord通知】===== 親チケット更新分析開始 ====="
          Rails.logger.info "【Discord通知】チケット ##{id}: #{subject}"
          Rails.logger.info "【Discord通知】プロジェクト: #{project.name}"
          Rails.logger.info "【Discord通知】トラッカー: #{tracker.name}"
          Rails.logger.info "【Discord通知】ステータス: #{status.name}"
          Rails.logger.info "【Discord通知】担当者: #{assigned_to&.name || 'なし'}"
          Rails.logger.info "【Discord通知】作成者: #{author.name}"
          Rails.logger.info "【Discord通知】作成日時: #{created_on}"
          Rails.logger.info "【Discord通知】更新日時: #{updated_on}"
          
          Rails.logger.info "【Discord通知】----- ジャーナル情報 -----"
          Rails.logger.info "【Discord通知】ジャーナルID: #{current_journal.id}"
          Rails.logger.info "【Discord通知】更新者: #{current_journal.user.name}"
          Rails.logger.info "【Discord通知】更新日時: #{current_journal.created_on}"
          Rails.logger.info "【Discord通知】コメント: '#{current_journal.notes}'"
          Rails.logger.info "【Discord通知】コメントあり: #{current_journal.notes.present? ? 'はい' : 'いいえ'}"
          
          Rails.logger.info "【Discord通知】----- フィールド変更詳細 -----"
          Rails.logger.info "【Discord通知】変更総数: #{current_journal.details.count}件"
          current_journal.details.each_with_index do |detail, index|
            Rails.logger.info "【Discord通知】変更#{index + 1}:"
            Rails.logger.info "【Discord通知】  種類: #{detail.property}"
            Rails.logger.info "【Discord通知】  フィールド: #{detail.prop_key}"
            Rails.logger.info "【Discord通知】  変更前: '#{detail.old_value}'"
            Rails.logger.info "【Discord通知】  変更後: '#{detail.value}'"
          end
          
          children_count = children.count
          Rails.logger.info "【Discord通知】----- 親子関係分析 -----"
          Rails.logger.info "【Discord通知】子チケットあり: はい"
          Rails.logger.info "【Discord通知】子チケット数: #{children_count}件"
          Rails.logger.info "【Discord通知】親チケットID: #{parent_id || 'なし'}"
          
          Rails.logger.info "【Discord通知】子チケット一覧:"
          children.each do |child|
            Rails.logger.info "【Discord通知】  - ##{child.id}: #{child.subject} (#{child.status.name})"
          end
          
          system_fields = ['lft', 'rgt', 'root_id', 'updated_on']
          meaningful_changes = current_journal.details.select do |detail|
            !system_fields.include?(detail.prop_key)
          end
          
          Rails.logger.info "【Discord通知】----- 変更内容分析 -----"
          Rails.logger.info "【Discord通知】システムフィールド: #{system_fields.join(', ')}"
          Rails.logger.info "【Discord通知】全変更フィールド: #{current_journal.details.map(&:prop_key).join(', ')}"
          Rails.logger.info "【Discord通知】ユーザー変更フィールド: #{meaningful_changes.map(&:prop_key).join(', ')}"
          Rails.logger.info "【Discord通知】システム変更のみ: #{current_journal.details.all? { |d| system_fields.include?(d.prop_key) } ? 'はい' : 'いいえ'}"
          
          Rails.logger.info "【Discord通知】----- 判定ロジック -----"
          no_meaningful_changes = meaningful_changes.empty?
          no_notes = current_journal.notes.blank?
          tree_only_changes = has_children && meaningful_changes.all? { |d| ['lft', 'rgt', 'root_id', 'parent_id'].include?(d.prop_key) }
          
          Rails.logger.info "【Discord通知】ユーザー変更なし: #{no_meaningful_changes ? 'はい' : 'いいえ'}"
          Rails.logger.info "【Discord通知】コメントなし: #{no_notes ? 'はい' : 'いいえ'}"
          Rails.logger.info "【Discord通知】ツリー構造変更のみ: #{tree_only_changes ? 'はい' : 'いいえ'}"
          
          if no_meaningful_changes && no_notes
            Rails.logger.info "【Discord通知】判定結果: 通知スキップ - ユーザー変更なし（子チケット追加による自動更新の可能性）"
            Rails.logger.info "【Discord通知】===== 分析終了 ====="
            return true
          end
          
          if tree_only_changes
            Rails.logger.info "【Discord通知】判定結果: 通知スキップ - ツリー構造変更のみ"
            Rails.logger.info "【Discord通知】===== 分析終了 ====="
            return true  
          end
          
          Rails.logger.info "【Discord通知】判定結果: 通知実行 - 意味のある変更を検出"
          Rails.logger.info "【Discord通知】===== 分析終了 ====="
          false
        end

        def handle_relation_addition
          # Check if a relation was added
          relation_detail = current_journal.details.find { |d| d.prop_key == 'relations' }
          return false unless relation_detail && relation_detail.old_value.blank? && relation_detail.value.present?

          Rails.logger.info "MESSENGER DEBUG: Checking relation addition for issue ##{id}"
          Rails.logger.info "MESSENGER DEBUG: Relation detail: #{relation_detail.old_value} -> #{relation_detail.value}"

          # Parse the relation information (format might vary)
          # Try to extract relation type and target issue
          relation_info = parse_relation_info(relation_detail.value)
          return false unless relation_info

          channels = Messenger.channels_for_project project
          url = Messenger.url_for_project project

          if Messenger.setting_for_project project, :messenger_direct_users_messages
            messenger_to_be_notified.each do |user|
              channels.append "@#{user.login}" unless user == current_journal.user
            end
          end

          return false unless channels.present? && url && Messenger.setting_for_project(project, :post_updates)
          return false if is_private? && !Messenger.setting_for_project(project, :post_private_issues)

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            current_url = "<#{Messenger.object_url self}|#{Messenger.markup_format subject}>"
            related_url = "<#{Messenger.object_url relation_info[:issue]}|#{Messenger.markup_format relation_info[:issue].subject}>" if relation_info[:issue]
            
            relation_text = get_relation_text(relation_info[:type])
            main_message = "#{Messenger.markup_format(project.name)} - #{relation_text} #{current_url} と #{related_url} が #{Messenger.markup_format(current_journal.user.to_s)} によって設定されました。"
            
            # Add mentions
            mentions = []
            if assigned_to.present?
              assignee_mention = Messenger.format_user_mention(assigned_to, project)
              mentions << "\n\n👤 担当者: #{assignee_mention}" if assignee_mention.present?
            end
            
            if watcher_users.any?
              watcher_mentions = []
              watcher_users.each do |user|
                mention = Messenger.format_user_mention(user, project)
                watcher_mentions << mention if mention.present?
              end
              
              if watcher_mentions.any?
                mentions << "\n👁️ ウォッチャー: #{watcher_mentions.uniq.join(' ')}"
              end
            end
            
            full_message = "#{main_message}#{mentions.join}"
            
            Rails.logger.info "MESSENGER DEBUG: Sending relation notification: #{full_message}"
            
            Messenger.speak full_message, channels, url, attachment: nil, project: project
          ensure
            ::I18n.locale = initial_language
          end
          
          true
        end

        def parse_relation_info(relation_value)
          # This is a simplified parser - might need adjustment based on actual Redmine format
          # Example formats: "relates #123", "blocks #456", "follows #789"
          return nil if relation_value.blank?
          
          # Try to extract relation type and issue number
          if relation_value.match(/(\w+)\s+#(\d+)/)
            relation_type = $1
            issue_id = $2.to_i
            target_issue = Issue.find_by(id: issue_id)
            
            return {
              type: relation_type,
              issue: target_issue
            } if target_issue
          end
          
          nil
        end

        def get_relation_text(relation_type)
          case relation_type.to_s.downcase
          when 'relates', 'related'
            '関連チケット'
          when 'blocks', 'blocked'
            'ブロックチケット'  
          when 'follows', 'followed'
            '後続チケット'
          when 'precedes'
            '先行チケット'
          when 'duplicates'
            '重複チケット'
          when 'duplicated'
            '重複元チケット'
          else
            '関連チケット'
          end
        end

        def send_parent_notification_if_child
          # Check if this issue has a parent (is a child issue)
          return unless parent.present?

          Rails.logger.info "MESSENGER DEBUG: Sending parent notification for child issue ##{id} to parent ##{parent.id}"

          # Send notification to parent issue's project channels
          channels = Messenger.channels_for_project parent.project
          url = Messenger.url_for_project parent.project

          if Messenger.setting_for_project parent.project, :messenger_direct_users_messages
            parent_to_be_notified = (parent.notified_users + parent.notified_watchers).compact.uniq
            parent_to_be_notified.each do |user|
              channels.append "@#{user.login}" unless user == author
            end
          end

          return unless channels.present? && url && Messenger.setting_for_project(parent.project, :post_updates)
          return if parent.is_private? && !Messenger.setting_for_project(parent.project, :post_private_issues)

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            parent_url = "<#{Messenger.object_url parent}|#{Messenger.markup_format parent.subject}>"
            child_url = "<#{Messenger.object_url self}|#{Messenger.markup_format subject}>"
            
            main_message = "#{Messenger.markup_format(parent.project.name)} - 親チケット #{parent_url} に 子チケット #{child_url} が #{Messenger.markup_format(author.to_s)} によって追加されました。"
            
            # Add mentions for parent issue
            parent_mentions = []
            if parent.assigned_to.present?
              assignee_mention = Messenger.format_user_mention(parent.assigned_to, parent.project)
              parent_mentions << "\n\n👤 担当者: #{assignee_mention}" if assignee_mention.present?
            end
            
            if parent.watcher_users.any?
              watcher_mentions = []
              parent.watcher_users.each do |user|
                mention = Messenger.format_user_mention(user, parent.project)
                watcher_mentions << mention if mention.present?
              end
              
              if watcher_mentions.any?
                parent_mentions << "\n👁️ ウォッチャー: #{watcher_mentions.uniq.join(' ')}"
              end
            end
            
            full_message = "#{main_message}#{parent_mentions.join}"
            
            Rails.logger.info "MESSENGER DEBUG: Sending parent notification: #{full_message}"
            
            # Create attachment with child ticket info in embed format
            attachment = {
              fields: [
                {
                  name: "子チケット",
                  value: "##{id} #{subject}",
                  short: true
                }
              ]
            }
            
            Messenger.speak full_message, channels, url, attachment: attachment, project: parent.project
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
            # Show simple description update message instead of full text
            { title: "説明", value: "説明を更新", short: true }
            
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
