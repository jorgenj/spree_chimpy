require 'spree_core'
require 'spree/chimpy/engine'
require 'spree/chimpy/subscription'
require 'spree/chimpy/workers/delayed_job'
require 'mailchimp'
require 'coffee_script'

module Spree::Chimpy
  extend self

  def config(&block)
    yield(Spree::Chimpy::Config)
  end

  def enqueue(event, object)
    payload = {class: object.class.name, id: object.id, object: object}
    ActiveSupport::Notifications.instrument("spree.chimpy.#{event}", payload)
  end

  def log(message)
    Rails.logger.info "spree_chimpy: #{message}"
  end

  def configured?
    Config.key.present? && !Config.lists.empty?
  end

  def reset
    @list = @api = @orders = nil
  end

  def api
    @api = Mailchimp::API.new(Config.key, Config.api_options) if configured?
  end

  def list
    if configured?
      @list ||= Interface::Lists.new(
        Config.lists.map do |list|
          Interface::List.new(
              list[:name],
              list[:customer_segment_name],
              list[:double_opt_in],
              list[:send_welcome_email],
              list[:list_id],
          )
        end
      )
    end
    @list
  end

  def orders
    @orders ||= Interface::Orders.new if configured?
  end

  def sync_merge_vars
    list.sync_merge_vars
  end

  def merge_vars(model)
    attributes = Config.merge_vars.except('EMAIL')

    array = attributes.map do |tag, method|
      value = model.send(method) if model.methods.include?(method)

      [tag, value.to_s]
    end

    Hash[array]
  end

  def ensure_list
    list.ensure_lists
  end

  def ensure_segment
    list.ensure_segments
  end

  def handle_event(event, payload = {})
    payload[:event] = event

    case
    when defined?(::Delayed::Job)
      ::Delayed::Job.enqueue(Spree::Chimpy::Workers::DelayedJob.new(payload))
    when defined?(::Sidekiq)
      Spree::Chimpy::Workers::Sidekiq.perform_async(payload.except(:object))
    else
      perform(payload)
    end
  end

  def perform(payload)
    return unless configured?

    event  = payload[:event].to_sym
    object = payload[:object] || payload[:class].constantize.find(payload[:id])

    case event
    when :order
      orders.sync(object)
    when :subscribe
      list.subscribe(object.email, merge_vars(object), customer: object.is_a?(Spree.user_class))
    when :unsubscribe
      list.unsubscribe(object.email)
    when :update_subscriber
      list.update_subscriber(object.email, merge_vars(object), customer: object.is_a?(Spree.user_class))
    end
  end
end
