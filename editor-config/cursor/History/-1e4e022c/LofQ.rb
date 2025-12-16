require_dependency "action/accounts/is_eligible_for_amf_refund"

describe Action::Accounts::IsEligibleForAmfRefund do
  subject { described_class.call(account: account) }

  let(:account) { create(:account, annual_fee_cents: 1000, unpaid_annual_charge_amount: 0) }

  describe "when the account has an AMF product, has paid the AMF and has no purchases or cash advances" do

    it "returns true" do
        it.is_expected.to be_success
    end
  end
end