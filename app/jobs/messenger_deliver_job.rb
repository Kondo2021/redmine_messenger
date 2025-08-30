# frozen_string_literal: true

require 'net/http'
require 'uri'

class MessengerDeliverJob < ActiveJob::Base
  queue_as :default

  def perform(url, params, notification_type = nil)
    uri = URI url
    http_options = { use_ssl: uri.scheme == 'https' }
    http_options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless RedmineMessenger.setting? :messenger_verify_ssl
    
    begin
      req = Net::HTTP::Post.new uri
      
      # Determine webhook format based on URL or notification type
      webhook_format = determine_webhook_format(url, notification_type)
      
      if webhook_format == 'discord_native'
        # Discord native webhook format
        discord_payload = convert_to_discord_format(params)
        req.content_type = 'application/json'
        req.body = discord_payload.to_json
      else
        # Slack-compatible format (default)
        req.set_form_data payload: params.to_json
      end
      
      Net::HTTP.start uri.hostname, uri.port, http_options do |http|
        response = http.request req
        Rails.logger.warn response.inspect unless [Net::HTTPSuccess, Net::HTTPRedirection, Net::HTTPOK].include? response
      end
    rescue StandardError => e
      Rails.logger.warn "cannot connect to #{url}"
      Rails.logger.warn e
    end
  end

  private

  def determine_webhook_format(url, notification_type)
    # If URL doesn't end with /slack and notification_type is discord, use Discord native format
    if notification_type == 'discord' && !url.end_with?('/slack')
      'discord_native'
    else
      'slack_compatible'
    end
  end

  def convert_to_discord_format(slack_params)
    discord_payload = {
      content: slack_params[:text]
    }

    # Add username if specified
    if slack_params[:username].present?
      discord_payload[:username] = slack_params[:username]
    end

    # Add avatar if specified
    if slack_params[:icon_url].present?
      discord_payload[:avatar_url] = slack_params[:icon_url]
    end

    # Convert attachments to Discord embeds
    if slack_params[:attachments]&.any?
      discord_payload[:embeds] = slack_params[:attachments].map do |attachment|
        embed = {}
        embed[:description] = attachment[:text] if attachment[:text].present?
        
        # Convert fields
        if attachment[:fields]&.any?
          embed[:fields] = attachment[:fields].map do |field|
            {
              name: field[:title] || field[:name],
              value: field[:value],
              inline: field[:short] == true
            }
          end
        end
        
        embed
      end
    end

    discord_payload
  end
end
