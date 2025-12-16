require_dependency "action/accounts/is_eligible_for_amf_refund"

describe Action::Accounts::IsEligibleForAmfRefund do
  subject { described_class.call(account: account) }

  let(:account) do
    FactoryPerson.create(
      Entity::Account,
      annual_fee_cents: annual_fee_cents,
      unpaid_annual_charge_amount: unpaid_annual_charge_amount
    )
  end

  let(:annual_fee_cents) { 1000 }
  let(:unpaid_annual_charge_amount) { 0 }
  let(:past_posted_transactions) { [] }
  let(:cycle_posted_transactions) { [] }

  before do
    allow(Persistence::Transaction).to receive(:past_posted!)
      .with(account_id: account.id)
      .and_return(past_posted_transactions)
    allow(Persistence::Transaction).to receive(:cycle_posted!)
      .with(account_id: account.id)
      .and_return(cycle_posted_transactions)
  end

  describe "when the account has an AMF product, has paid the AMF and has no posted purchases or cash advances" do
    it { is_expected.to be_success }

    it "returns true" do
      expect(subject.is_elegible_for_amf_refund).to be true
    end
  end

  describe "when the account does not have an AMF product" do
    let(:annual_fee_cents) { 0 }

    it { is_expected.to be_success }

    it "returns false" do
      expect(subject.is_elegible_for_amf_refund).to be false
    end
  end

  describe "when the account paid any portion of the AMF" do
    let(:unpaid_annual_charge_amount) { rand(1..annual_fee_cents) }

    it { is_expected.to be_success }

    it "returns false" do
      expect(subject.is_elegible_for_amf_refund).to be false
    end
  end

  describe "when the account has posted purchases" do
    let(:purchase_transaction) do
      FactoryPerson.create(Entity::PostedTransaction, type_display: "Purchase")
    end

    let(:past_posted_transactions) { [purchase_transaction] }

    it { is_expected.to be_success }

    it "returns false" do
      expect(subject.is_elegible_for_amf_refund).to be false
    end
  end

  describe "when the account has a cash advance transaction" do
    let(:cash_advance_transaction) do
      FactoryPerson.create(Entity::PostedTransaction, type_display: "Cash Advance")
    end

    let(:cycle_posted_transactions) { [cash_advance_transaction] }

    it { is_expected.to be_success }

    it "returns false" do
      expect(subject.is_elegible_for_amf_refund).to be false
    end
  end

  describe "when the account has a cash transaction" do
    let(:cash_transaction) do
      FactoryPerson.create(Entity::PostedTransaction, type_display: "Cash")
    end

    let(:past_posted_transactions) { [cash_transaction] }

    it { is_expected.to be_success }

    it "returns false" do
      expect(subject.is_elegible_for_amf_refund).to be false
    end
  end
end
