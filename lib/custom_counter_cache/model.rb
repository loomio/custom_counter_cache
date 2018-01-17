require 'active_support/concern'
RAILS_GTE_5_1 = ::ActiveRecord.gem_version >= ::Gem::Version.new("5.1.0.beta1")

module CustomCounterCache::Model
  extend ActiveSupport::Concern

  module ClassMethods
    def define_counter_cache(cache_column, &block)
      return unless table_exists?

      # counter accessors
      unless column_names.include?(cache_column.to_s)
        has_many :counters, as: :countable, dependent: :destroy
        define_method "#{cache_column}" do
          # check if the counter is loaded
          if counters.loaded? && counter = counters.detect{|c| c.key == cache_column.to_s }
            counter.value
          else
            counters.find_by_key(cache_column.to_s).try(:value).to_i
          end
        end
        define_method "#{cache_column}=" do |count|
          if ( counter = counters.find_by_key(cache_column.to_s) )
            counter.update_attribute :value, count.to_i
          else
            counters.create key: cache_column.to_s, value: count.to_i
          end
        end
      end

      # counter update method
      define_method "update_#{cache_column}" do
        if self.class.column_names.include?(cache_column.to_s)
          update_attribute cache_column, block.call(self)
        else
          send "#{cache_column}=", block.call(self)
        end
      end

    rescue StandardError => e
      # Support Heroku's database-less assets:precompile pre-deploy step:
      raise e unless ENV['DATABASE_URL'].to_s.include?('//user:pass@127.0.0.1/')
    end

    def update_counter_cache(association, cache_column, options = {})
      return unless table_exists?

      association  = association.to_sym
      cache_column = cache_column.to_sym
      method_name  = "callback_#{association}_#{cache_column}".to_sym
      reflection   = reflect_on_association(association)
      foreign_key  = reflection.try(:foreign_key) || reflection.association_foreign_key


      changed_method_name = if RAILS_GTE_5_1
        'saved_change_to_attribute?'
      else
        'attributed_changed?'
      end

      # define callback
      define_method method_name do
        # update old association
        if send(changed_method_name, foreign_key) || ( reflection.options[:polymorphic] && send(changed_method_name, "#{association}_type") )
          old_id = send("attribute_before_last_save", foreign_key)
          klass = if reflection.options[:polymorphic]
            ( send("attribute_before_last_save", "#{association}_type") || send("#{association}_type") ).constantize
          else
            reflection.klass
          end
          if ( old_id && record = klass.find_by(id: old_id) )
            record.send("update_#{cache_column}")
          end
        end
        # update new association
        if ( record = send(association) )
          record.send("update_#{cache_column}")
        end
      end

      skip_callback = Proc.new { |callback, opts|
        (opts[:except].present? && opts[:except].include?(callback)) ||
        (opts[:only].present?   && !opts[:only].include?(callback))
      }

      # set callbacks
      after_create  method_name, options unless skip_callback.call(:create, options)
      after_update  method_name, options unless skip_callback.call(:update, options)
      after_destroy method_name, options unless skip_callback.call(:destroy, options)

    rescue StandardError => e
      # Support Heroku's database-less assets:precompile pre-deploy step:
      raise e unless ENV['DATABASE_URL'].to_s.include?('//user:pass@127.0.0.1/')
    end
  end
end
