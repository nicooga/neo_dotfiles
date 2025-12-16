# frozen_string_literal: true

require './platforms/account_management/modules/refund/constants'
require './platforms/account_management/modules/refund/entities/refund'
require './platforms/account_management/modules/refund/errors'

# debit schedule is required as it needs to be updated after completing a refund
require './platforms/loan_core/modules/debit_schedule/interface'

module AccountManagement
  module Refund
    module Models
      class Refund < ApplicationRecord
        self.table_name = 'refunds'

        belongs_to :payment_loan_task,
                   class_name:  'LoanTask',
                   foreign_key: :payment_loan_task_uuid,
                   primary_key: :uuid

        belongs_to :refund_loan_task,
                   class_name:  'LoanTask',
                   foreign_key: :give_refund_loan_task_uuid,
                   primary_key: :uuid

        belongs_to :servicing_account,
                   class_name:  '::Servicing::Account',
                   foreign_key: :servicing_account_uuid,
                   primary_key: :uuid

        belongs_to :requester,
                   class_name:  'AdminUser',
                   foreign_key: :requester_admin_user_uuid,
                   primary_key: :uuid

        belongs_to :reviewer,
                   class_name:  'AdminUser',
                   foreign_key: :reviewer_admin_user_uuid,
                   primary_key: :uuid

        validates :servicing_account_uuid, presence: true
        validates_inclusion_of :status, in: Constants::REFUND_STATUSES
        validates :amount_cents, presence: true, numericality: true
        validates :refund_reason, presence: true
        validates_inclusion_of :refund_type, in: Constants::REFUND_TYPES

        scope :requested, -> { where(status: Constants::REQUESTED_STATUS) }
        scope :pending, -> { where(status: Constants::PENDING_STATUS) }
        scope :returned, -> { where(status: Constants::RETURNED_STATUS) }

        # scopes for refund statuses
        self.singleton_class.class_eval do
          Constants::REFUND_STATUSES.each do |status|
            define_method(status.to_sym) { where(status: status) }
          end
        end

        def to_entity
          Entities::Refund.new(attributes.merge(debit_account: debit_account))
        end

        def debit_account
          refund_type == Constants::OVERPAYMENT_TYPE ?
            Constants::DEBIT_ACCOUNT_UNEARNED_CASH :
            Constants::DEBIT_ACCOUNT_REFUNDS_PAYABLE
        end

        def reject!
          ActiveRecord::Base.transaction do
            self.status = Constants::REJECTED_STATUS
            self.save
          end
        end

        def approve!
          ActiveRecord::Base.transaction do
            self.status = Constants::APPROVED_STATUS
            self.save
          end
        end

        def complete!
          result = ActiveRecord::Base.transaction do
            self.status = Constants::COMPLETE_STATUS
            unless save && self.refund_loan_task.complete!
              raise CompletionError.new('failed to complete refund!', refund_uuid: self.uuid)
            end
          end

          if servicing_account.interface.core_banking_debit_schedule_enabled?
            debit_schedule_interface = ::LoanCore::Modules::DebitSchedule::Interface.new(loan: servicing_account.product)
            debit_schedule_interface.update_payments!('Refund')
          end

          result
        end

        def return!
          ActiveRecord::Base.transaction do
            self.status = Constants::RETURNED_STATUS
            raise CompletionError.new('failed to return refund!', refund_uuid: self.uuid) unless save
            self.refund_loan_task.return
            self.refund_loan_task.update!(status: Constants::RETURNED_STATUS)
          end
        end

        def cancel!
          result = ActiveRecord::Base.transaction do
            self.status = Constants::CANCELLED_STATUS
            unless save && self.refund_loan_task.cancel!
              raise CompletionError.new('failed to cancel refund!', refund_uuid: self.uuid)
            end
          end

          if servicing_account.interface.core_banking_debit_schedule_enabled?
            debit_schedule_interface = ::LoanCore::Modules::DebitSchedule::Interface.new(loan: servicing_account.product)
            debit_schedule_interface.update_payments!('Refund')
          end

          result
        end
      end
    end
  end
end
