//
//  Copyright (c) 2020-2021 MobileCoin. All rights reserved.
//

import Foundation

struct PreparedTxInput {
    /// - Returns: `.failure` when `knownTxOut` isn't in `ring`.
    static func make(knownTxOut: KnownTxOut, ring: [(TxOut, TxOutMembershipProof)])
        -> Result<PreparedTxInput, InvalidInputError>
    {
        let ring = ring.sorted { $0.0.publicKey.lexicographicallyPrecedes($1.0.publicKey) }

        guard let realInputIndex =
                ring.firstIndex(where: { $0.0.publicKey == knownTxOut.publicKey })
        else {
            logger.info("failure - txOut not found in ring")
            return .failure(InvalidInputError("TxOut not found in ring"))
        }

        logger.info("success")
        return .success(
            PreparedTxInput(knownTxOut: knownTxOut, ring: ring, realInputIndex: realInputIndex))
    }

    let knownTxOut: KnownTxOut
    let ring: [(TxOut, TxOutMembershipProof)]
    let realInputIndex: Int

    private init(knownTxOut: KnownTxOut, ring: [(TxOut, TxOutMembershipProof)], realInputIndex: Int)
    {
        self.knownTxOut = knownTxOut
        self.ring = ring
        self.realInputIndex = realInputIndex
    }
}
