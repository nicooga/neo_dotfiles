require_dependency "action/accounts/is_eligible_for_amf_refund"

describe Action::Accounts::IsEligibleForAmfRefund do
  let(:account) { create(:account) }
  let(:result) { described_class.call(account: account) }

  it "returns true if the account is eligible for an AMF refund" do
    expect(result).to be_success
  end
end