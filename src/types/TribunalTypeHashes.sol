// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Type string constants extracted from Tribunal.sol
string constant MANDATE_TYPESTRING =
    "Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)";

string constant MANDATE_FILL_TYPESTRING =
    "Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)";

string constant MANDATE_RECIPIENT_CALLBACK_TYPESTRING =
    "Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)";

string constant MANDATE_BATCH_COMPACT_TYPESTRING =
    "Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)";

string constant MANDATE_LOCK_TYPESTRING =
    "Mandate_Lock(bytes12 lockTag,address token,uint256 amount)";

string constant COMPACT_WITH_MANDATE_TYPESTRING =
    "BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Lock[] commitments,Mandate mandate)Lock(bytes12 lockTag,address token,uint256 amount)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)";

string constant ADJUSTMENT_TYPESTRING =
    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)";

// Typehash constants (these should match the values in Tribunal.sol)
bytes32 constant MANDATE_TYPEHASH =
    0x78eb489c4f76cd1d9bc735e1f4e8369b94ed75b11b35b0d5882f9c4c856a7a90;

bytes32 constant MANDATE_FILL_TYPEHASH =
    0x02ccd0f55bde7e5174b479837dce09e4f95101b3b6dfc43be8d6d42a9bd66590;

bytes32 constant MANDATE_RECIPIENT_CALLBACK_TYPEHASH =
    0x4fc45936139e9bc61053b9f1f238d4205ccd3dddaf02907ca21557ffd35160ae;

bytes32 constant MANDATE_BATCH_COMPACT_TYPEHASH =
    0xd1b7b490818c27a08c0bf3264fa04437fb7d4e669ade6acb8e5dde31e2d0b1c2;

bytes32 constant MANDATE_LOCK_TYPEHASH =
    0xce4f0854d9091f37d9dfb64592eee0de534c6680a5444fd55739b61228a6e0b0;

bytes32 constant COMPACT_TYPEHASH_WITH_MANDATE =
    0xab0a4c35b998b2b78c7b8f899e1423371e4fbed77d7c8e4fc3b03816cea512a5;

bytes32 constant ADJUSTMENT_TYPEHASH =
    0xe829b2a82439f37ac7578a226e337d334e0ee0da2f05ab63891c19cb84714414;

// Witness typestring (partial string that is provided to The Compact by Tribunal to process claims)
string constant WITNESS_TYPESTRING =
    "address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context";
