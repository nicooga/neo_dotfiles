class Servicing::Policy < ApplicationRecord
  include UUIDHelper

  self.table_name = 'servicing_policies'

  belongs_to :product, polymorphic: true, primary_key: :uuid, foreign_key: :product_uuid, inverse_of: :servicing_policy_class

  def self.build_with_product_and_policy!(product, servicing_policy)
    if product.servicing_policy_class.present?
      if product.servicing_policy_class.policy_class == servicing_policy
        return
      end
      raise 'Attempted to change servicing policy assignment. Please investigate.'
    end

    product.create_servicing_policy_class(policy: servicing_policy)
  end

  def policy_class
    @@policy_classes ||= {}
    @@policy_classes[policy] ||= policy.constantize
  end
end
