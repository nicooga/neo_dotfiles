require_dependency "action/accounts/is_eligible_for_amf_refund"

describe Action::Accounts::IsEligibleForAmfRefund do
  subject { described_class.call(account: account) }

  let(:account) { FactoryPerson.create(Entity::Account, annual_fee_cents: 1000, unpaid_annual_charge_amount: 0) }

  describe "when the account has an AMF product, has paid the AMF and has no posted purchases or cash advances" do
    it { is_expected.to be_true }
  end
end