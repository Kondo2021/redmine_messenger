# frozen_string_literal: true

module RedmineMessenger
  module Hooks
    class ViewHook < Redmine::Hook::ViewListener
      def view_users_form(context = {})
        form = context[:form]
        return '' unless form

        content_tag(:div, class: 'box tabular') do
          content_tag(:fieldset) do
            content_tag(:legend, l(:label_messenger_settings)) +
            content_tag(:p) do
              form.text_field(:discord_username, size: 30) +
              content_tag(:em, l(:label_discord_username_info), class: 'info')
            end +
            content_tag(:p) do
              form.text_field(:discord_user_id, size: 30) +
              content_tag(:em, l(:label_discord_user_id_info), class: 'info')
            end
          end
        end
      end

      def view_my_account(context = {})
        form = context[:form]
        return '' unless form

        content_tag(:div, class: 'box tabular') do
          content_tag(:fieldset) do
            content_tag(:legend, l(:label_messenger_settings)) +
            content_tag(:p) do
              form.text_field(:discord_username, size: 30) +
              content_tag(:em, l(:label_discord_username_info), class: 'info')
            end +
            content_tag(:p) do
              form.text_field(:discord_user_id, size: 30) +
              content_tag(:em, l(:label_discord_user_id_info), class: 'info')
            end
          end
        end
      end
    end
  end
end