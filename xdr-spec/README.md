The prompt I used to generate the test (with some handholding)

Write a protocol 26 test for https://github.com/stellar/stellar-protocol/blob/master/core/cap-0073.md
1. Read ledger-close-meta-schema-v25.0.0.json for the JSON specification.
2. Read ledger-close-meta-business-logic-spec.json for the business logic spec.
3. Read the examples in the examples directory. These are working examples taken from a running network.
4. For any G keys you need to use, use one from g-keys.txt. This is important because the keys are validated downstream.
5. Now can you create a test xdr that tests the logic specified in https://github.com/stellar/stellar-protocol/blob/master/core/cap-0073.md? Specifically, test that an invocation to change_trust can create a trustline, and an invocation to transfer to a non-existent G account creates that account.
6. Once you have a test, make sure to validate that the test matches the schema from step 1 using a tool (don't attempt to write this from scratch)
7. Validate against the spec from step 2. The generated test MUST pass validation for both this step and step 6. 