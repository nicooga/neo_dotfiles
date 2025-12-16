# Test Cases for `IsEligibleForAmfRefund`

## Eligibility Criteria Summary

An account is **ELIGIBLE** when ALL of these are true:

1. `annual_fee_cents > 0` (has AMF product)
2. `unpaid_annual_charge_amount >= annual_fee_cents` (AMF not yet paid)
3. No posted transactions with `type_display` in `["Purchase", "Cash Advance", "Cash"]`

---

## Test Cases

### ✅ TC1: ELIGIBLE - New AMF account with no activity

**Expected Result:** `true`

**Spreadsheet Criteria:**

| Column | Criteria |
|--------|----------|
| `ANNL_CHRG_AM` | > 0 (has annual fee) |
| `CRRN_BAL_AM` | = `ANNL_CHRG_AM` or close (only the fee charged) |
| `MNTH_GRSS_ACTV_CT` | = 0 or very low (no/minimal activity) |
| `OPEN_DT` | Recent (newly opened) |

**Verification:** Check that `posted_transactions` returns empty or only non-disqualifying types (fees, adjustments).

---

### ❌ TC2: NOT ELIGIBLE - No AMF product

**Expected Result:** `false` (fails at `has_amf_product?`)

**Spreadsheet Criteria:**

| Column | Criteria |
|--------|----------|
| `ANNL_CHRG_AM` | = 0 or empty |

---

### ❌ TC3: NOT ELIGIBLE - AMF partially/fully paid

**Expected Result:** `false` (fails at `has_paid_amf?`)

**Spreadsheet Criteria:**

| Column | Criteria |
|--------|----------|
| `ANNL_CHRG_AM` | > 0 |
| `LAST_PYMT_DT` | Has a value (payment was made) |

**Note:** `unpaid_annual_charge_amount` isn't in spreadsheet - verify via API that it's less than `annual_fee_cents`.

---

### ❌ TC4: NOT ELIGIBLE - Has Purchase transactions

**Expected Result:** `false` (fails at `has_posted_disqualifying_transactions?`)

**Spreadsheet Criteria (lenient):**

| Column | Criteria |
|--------|----------|
| `ANNL_CHRG_AM` | > 0 (has annual fee) |
| `MNTH_GRSS_ACTV_CT` | > 0 (has activity) |
| `CRRN_BAL_AM` | > `ANNL_CHRG_AM` (balance includes purchases) |

**Filter Formula:**

```excell
=AND(S2 > 0, U2 > 0, H2 > S2)
```

*Adjust column letters to match your spreadsheet.*

**Testing approach:**

1. Find an account matching above criteria
2. Run `test_eligibility("account_id")` to verify it has disqualifying transactions
3. If `has_paid_amf?: true`, manually adjust the account in Fiserv sandbox to make AMF unpaid
4. Re-run to confirm it now fails at `has_posted_disqualifying_transactions?`

---

### ❌ TC5: NOT ELIGIBLE - Has Cash Advance transactions

**Expected Result:** `false` (fails at `has_posted_disqualifying_transactions?`)

**Spreadsheet Criteria:**

| Column | Criteria |
|--------|----------|
| `ANNL_CHRG_AM` | > 0 |
| `CASH_ADVN_OTST_BAL_AM` | > 0 (has cash advance balance) |

---

### ❌ TC6: NOT ELIGIBLE - Multiple disqualifying conditions

**Expected Result:** `false`

**Spreadsheet Criteria:**

| Column | Criteria |
|--------|----------|
| `ANNL_CHRG_AM` | > 0 |
| `CRRN_BAL_AM` | > `ANNL_CHRG_AM` |
| `LAST_PYMT_DT` | Has value |
| `MNTH_GRSS_ACTV_CT` | > 0 |

---

## Edge Cases

### ⚠️ TC7: Edge - AMF account, zero balance, no transactions

**Expected Result:** `true` (if AMF still unpaid)

**Spreadsheet Criteria:**

| Column | Criteria |
|--------|----------|
| `ANNL_CHRG_AM` | > 0 |
| `CRRN_BAL_AM` | = 0 |

**Note:** This might indicate AMF was refunded/waived already. Verify `unpaid_annual_charge_amount` via API.

---

### ⚠️ TC8: Edge - Closed account with AMF

**Expected Result:** Depends on other criteria

**Spreadsheet Criteria:**

| Column | Criteria |
|--------|----------|
| `ANNL_CHRG_AM` | > 0 |
| `EXTR_STTS_CD` | = "C" (Closed) |

---

## Console Helper for QA

```ruby
def setup_test_account(fiserv_ref)
  existing = Models::Account.find_by(first_data_account_reference: fiserv_ref)
  
  unless existing
    customer = Models::Customer.first || Models::Customer.create!(
      id: SecureRandom.uuid,
      simple_id: 99999,
      first_data_customer_reference: "C00000000000000000000000"
    )

    existing = Models::Account.create!(
      id: SecureRandom.uuid,
      simple_id: Models::Account.maximum(:simple_id).to_i + 1,
      customer: customer,
      first_data_account_reference: fiserv_ref,
      billing_cycle_code: 11,
      application_id: SecureRandom.uuid
    )
  end

  Persistence::Account.find!(id: existing.id)[:account]
end
```

Usage:

```ruby
acc = setup_test_account('fiserv account id')
Action::Accounts::IsEligibleForAmfRefund.call(account: acc)
```

Sometimes the chosen MCycle account does not meet the criteria, or check returns the expected result but for the wrong reasons. For that reason, it's advisable to do a more thorough check by using the checks in this little script:

```ruby
def test_eligibility(fiserv_account_id)
  acc = setup_test_account(fiserv_account_id)
  action = Action::Accounts::IsEligibleForAmfRefund.new(account: acc)

  has_amf_product = action.send(:has_amf_product?)
  has_paid_amf = action.send(:has_paid_amf?)
  has_disqualifying_txns = action.send(:has_posted_disqualifying_transactions?)

  txns = action.send(:posted_transactions)
  txn_types = txns.map(&:type_display).tally

  result = action.call

  puts <<~OUTPUT.strip_heredoc
    === Account: #{fiserv_account_id} ===

    Account Data:
      - annual_fee_cents: #{acc.annual_fee_cents}
      - unpaid_annual_charge_amount: #{acc.unpaid_annual_charge_amount}
      - external_status: #{acc.external_status}

    Transactions (#{txns.count} total):
      - types: #{txn_types.empty? ? 'none' : txn_types}

    Eligibility Checks:
      - has_amf_product?: #{has_amf_product}
      - has_paid_amf?: #{has_paid_amf}
      - has_posted_disqualifying_transactions?: #{has_disqualifying_txns}

    Result: #{result}
    ========================================
  OUTPUT

  [acc, action]
end
```

Usage:

```ruby
acc, action = test_eligibility 'fiserv account id'; nil
```

### REMOVE ME

```ruby
def find_matching_account(fiserv_account_ids, transaction_type:)
  fiserv_account_ids.each do |fid|
    acc, action = test_eligibility(fid)
    posted_transactions_tally_by_type = action.send(:posted_transactions).map(&:type_display).tally

    if (
      action.output[:is_elegible_for_amf_refund] && 
      posted_transactions_tally_by_type[transaction_type] > 0
    )
      return [acc, action]
    end
  end
end
```

## Test Execution Log

| Test Case | Account Reference | Expected | Actual | Status |
|-----------|-------------------|----------|--------|--------|
| TC1       | 5159420119684700  | `true`   | `true` | ✅     |
| TC2       | 5159420100002359  | `false`  | `false`| ✅     |
| TC3       | 5159420100001195  | `false`  | `false`| ✅     |
| TC4       | 5159420100176104  | `false`  | `false`| ✅     |
| TC5       |                   | `false`  |        |        |
| TC6       |                   | `false`  |        |        |
| TC7       |                   | `true`   |        |        |
| TC8       |                   | TBD      |        |        |
