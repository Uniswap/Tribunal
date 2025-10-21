// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/* Example payload signed by swapper for a cross-chain swap with a decomposed same-chain swap on source chain + bridge + register same-chain swap on target chain:
{
    arbiter: SOURCE_CHAIN_TRIBUNAL_CONTRACT,
    sponsor: SWAPPER,
    nonce: SOURCE_CLAIM_NONCE,
    expires: SOURCE_CLAIM_EXPIRATION,
    commitments: [
        {
            lockTag: ONCHAIN_ALLOCATOR_LOCK_TAG_WITH_DEFAULT_PARAMS,
            token: SOURCE_CHAIN_UNI,
            amount: 1_000_000_000_000_000_000
        }
    ],
    mandate: {
        adjuster: UNISWAP_TEE,
        fills: [
            {
                chainId: TARGET_CHAIN_ID,
                tribunal: TARGET_CHAIN_TRIBUNAL_CONTRACT,
                expires; CROSS_CHAIN_FILL_EXPIRATION,
                fillToken: TARGET_CHAIN_USDC,
                minimumFillAmount: 10_017_500,
                baselinePriorityFee; 1_000_000_000,
                scalingFactor; 0x00000000000000000000000000000000000000000000000000000de0b6b3a7640005,
                priceCurve: [0x0002000000000000000000000000000000000000000000000de0b6b3a7640002, 0x0003000000000000000000000000000000000000000000000de0b6b3a7640001]
                recipient: SWAPPER,
                recipientCallback: [],
                salt: 0x1234567890123456789012345678901234567890123456789012345678901234
            },
            {
                chainId: SOURCE_CHAIN_ID,
                tribunal: SOURCE_CHAIN_TRIBUNAL_CONTRACT,
                expires; SAME_CHAIN_FILL_EXPIRATION,
                fillToken: ETH,
                minimumFillAmount: 2_404_400_000_000_000,
                baselinePriorityFee: 0,
                scalingFactor: 0x00000000000000000000000000000000000000000000000000000de0b6b3a7640000,
                priceCurve: [0x0002000000000000000000000000000000000000000000000de0b6b3a7640005, 0x0003000000000000000000000000000000000000000000000de0b6b3a7640003]
                recipient: ACROSS_ADAPTER,
                recipientCallback: [
                    {
                        chainId: TARGET_CHAIN_ID,
                        compact: {
                            arbiter: TARGET_CHAIN_TRIBUNAL_CONTRACT,
                            sponsor: SWAPPER,
                            nonce: TARGET_CLAIM_NONCE,
                            expires: TARGET_CLAIM_EXPIRATION,
                            commitments: [
                                {
                                    lockTag: ONCHAIN_ALLOCATOR_LOCK_TAG_WITH_DEFAULT_PARAMS,
                                    token: ETH,
                                    amount: PLACEHOLDER_VALUE_POPULATED_BY_ADAPTER
                                }
                            ],
                            mandate: {
                                adjuster: UNISWAP_TEE,
                                fills: [
                                    {
                                        chainId: TARGET_CHAIN_ID,
                                        tribunal: TARGET_CHAIN_TRIBUNAL_CONTRACT,
                                        expires; TARGET_CHAIN_FILL_EXPIRATION,
                                        fillToken: TARGET_CHAIN_USDC,
                                        minimumFillAmount: 10_010_000,
                                        baselinePriorityFee; 1_000_000_000,
                                        scalingFactor; 0x00000000000000000000000000000000000000000000000000000de0b6b3a7640005,
                                        priceCurve: [0x0002000000000000000000000000000000000000000000000de0b6b3a7640002, 0x0003000000000000000000000000000000000000000000000de0b6b3a7640001]
                                        recipient: SWAPPER,
                                        recipientCallback: [],
                                        salt: 0x1234567890123456789012345678901234567890123456789012345678901234
                                    }
                                ]
                            }
                        },
                        context: "0x"
                    }
                ],
                salt: 0x1234567890123456789012345678901234567890123456789012345678901234
            },
        ]
    }
}
*/

// Type string constants extracted from Tribunal.sol
string constant MANDATE_TYPESTRING =
    "Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,Mandate_FillComponent[] components,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_FillComponent(address fillToken,uint256 minimumFillAmount,address recipient,bool applyScaling)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)";

string constant MANDATE_FILL_TYPESTRING =
    "Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,Mandate_FillComponent[] components,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_FillComponent(address fillToken,uint256 minimumFillAmount,address recipient,bool applyScaling)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)";

string constant MANDATE_FILL_COMPONENT_TYPESTRING =
    "Mandate_FillComponent(address fillToken,uint256 minimumFillAmount,address recipient,bool applyScaling)";

string constant MANDATE_RECIPIENT_CALLBACK_TYPESTRING =
    "Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,Mandate_FillComponent[] components,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_FillComponent(address fillToken,uint256 minimumFillAmount,address recipient,bool applyScaling)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)";

string constant MANDATE_BATCH_COMPACT_TYPESTRING =
    "Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,Mandate_FillComponent[] components,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_FillComponent(address fillToken,uint256 minimumFillAmount,address recipient,bool applyScaling)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)";

string constant MANDATE_LOCK_TYPESTRING =
    "Mandate_Lock(bytes12 lockTag,address token,uint256 amount)";

string constant COMPACT_WITH_MANDATE_TYPESTRING =
    "BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Lock[] commitments,Mandate mandate)Lock(bytes12 lockTag,address token,uint256 amount)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,Mandate_FillComponent[] components,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_FillComponent(address fillToken,uint256 minimumFillAmount,address recipient,bool applyScaling)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)";

string constant ADJUSTMENT_TYPESTRING =
    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)";

// Typehash constants (these should match the values in Tribunal.sol)
bytes32 constant MANDATE_TYPEHASH =
    keccak256(bytes(MANDATE_TYPESTRING));

bytes32 constant MANDATE_FILL_TYPEHASH =
    keccak256(bytes(MANDATE_FILL_TYPESTRING));

bytes32 constant MANDATE_FILL_COMPONENT_TYPEHASH =
    keccak256(bytes(MANDATE_FILL_COMPONENT_TYPESTRING));

bytes32 constant MANDATE_RECIPIENT_CALLBACK_TYPEHASH =
    keccak256(bytes(MANDATE_RECIPIENT_CALLBACK_TYPESTRING));

bytes32 constant MANDATE_BATCH_COMPACT_TYPEHASH =
    keccak256(bytes(MANDATE_BATCH_COMPACT_TYPESTRING));

bytes32 constant MANDATE_LOCK_TYPEHASH =
    0xce4f0854d9091f37d9dfb64592eee0de534c6680a5444fd55739b61228a6e0b0;

bytes32 constant COMPACT_TYPEHASH_WITH_MANDATE =
    keccak256(bytes(COMPACT_WITH_MANDATE_TYPESTRING));

bytes32 constant ADJUSTMENT_TYPEHASH =
    0xe829b2a82439f37ac7578a226e337d334e0ee0da2f05ab63891c19cb84714414;

// Witness typestring (partial string that is provided to The Compact by Tribunal to process claims)
string constant WITNESS_TYPESTRING =
    "address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,Mandate_FillComponent[] components,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_FillComponent(address fillToken,uint256 minimumFillAmount,address recipient,bool applyScaling)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context";
