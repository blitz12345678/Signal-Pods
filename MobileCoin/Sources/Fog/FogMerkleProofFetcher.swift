//
//  Copyright (c) 2020-2021 MobileCoin. All rights reserved.
//

// swiftlint:disable multiline_arguments multiline_function_chains
// swiftlint:disable closure_body_length

import Foundation
import LibMobileCoin

enum FogMerkleProofFetcherError: Error {
    case connectionError(ConnectionError)
    case outOfBounds(blockCount: UInt64, ledgerTxOutCount: UInt64)
}

extension FogMerkleProofFetcherError: CustomStringConvertible {
    var description: String {
        "Fog Merkle Proof Fetcher error: " + {
            switch self {
            case .connectionError(let innerError):
                return "\(innerError)"
            case let .outOfBounds(blockCount: blockCount, ledgerTxOutCount: txOutCount):
                return "Out of bounds: blockCount: \(blockCount), globalTxOutCount: \(txOutCount)"
            }
        }()
    }
}

struct FogMerkleProofFetcher {
    private let serialQueue: DispatchQueue
    private let fogMerkleProofService: FogMerkleProofService

    init(fogMerkleProofService: FogMerkleProofService, targetQueue: DispatchQueue?) {
        self.serialQueue = DispatchQueue(label: "com.mobilecoin.\(Self.self)", target: targetQueue)
        self.fogMerkleProofService = fogMerkleProofService
    }

    func getOutputs(
        globalIndicesArray: [[UInt64]],
        merkleRootBlock: UInt64,
        maxNumIndicesPerQuery: Int,
        completion: @escaping (
            Result<[[(TxOut, TxOutMembershipProof)]], FogMerkleProofFetcherError>
        ) -> Void
    ) {
        getOutputs(
            globalIndices: globalIndicesArray.flatMap { $0 },
            merkleRootBlock: merkleRootBlock,
            maxNumIndicesPerQuery: maxNumIndicesPerQuery
        ) {
            completion($0.flatMap { allResults in
                globalIndicesArray.map { globalIndices in
                    guard let results = allResults[globalIndices] else {
                        return .failure(.connectionError(.invalidServerResponse(
                            "global txout indices not found in " +
                            "GetOutputs reponse. globalTxOutIndices: \(globalIndices), returned " +
                            "outputs: \(allResults)")))
                    }
                    return .success(results)
                }.collectResult()
            })
        }
    }

    func getOutputs(
        globalIndices: [UInt64],
        merkleRootBlock: UInt64,
        maxNumIndicesPerQuery: Int,
        completion: @escaping (
            Result<[UInt64: (TxOut, TxOutMembershipProof)], FogMerkleProofFetcherError>
        ) -> Void
    ) {
        logger.info("")
        let globalIndicesArrays =
            globalIndices.chunked(maxLength: maxNumIndicesPerQuery).map { Array($0) }
        globalIndicesArrays.mapAsync({ chunk, callback in
            getOutputs(globalIndices: chunk, merkleRootBlock: merkleRootBlock, completion: callback)
        }, serialQueue: serialQueue, completion: {
            completion($0.map { arrayOfOutputMaps in
                arrayOfOutputMaps.reduce(into: [:]) { outputMapAccum, outputMap in
                    outputMapAccum.merge(outputMap, uniquingKeysWith: { key1, _ in key1 })
                }
            })
        })
    }

    func getOutputs(
        globalIndices: [UInt64],
        merkleRootBlock: UInt64,
        completion: @escaping (
            Result<[UInt64: (TxOut, TxOutMembershipProof)], FogMerkleProofFetcherError>
        ) -> Void
    ) {
        logger.info("")
        var request = FogLedger_GetOutputsRequest()
        request.indices = globalIndices
        request.merkleRootBlock = merkleRootBlock
        fogMerkleProofService.getOutputs(request: request) {
            completion(
                $0.mapError { .connectionError($0) }
                    .flatMap { Self.parseResponse(response: $0) })
        }
    }

    private static func parseResponse(response: FogLedger_GetOutputsResponse)
        -> Result<[UInt64: (TxOut, TxOutMembershipProof)], FogMerkleProofFetcherError>
    {
        response.results.map { outputResult in
            switch outputResult.resultCodeEnum {
            case .exists:
                guard let txOut = TxOut(outputResult.output),
                      let membershipProof = TxOutMembershipProof(outputResult.proof)
                else {
                    logger.info("FAILURE: returned invalid result")
                    return .failure(.connectionError(.invalidServerResponse(
                        "FogMerkleProofService.getOutputs returned " +
                        "invalid result.")))
                }
                logger.info("SUCCESS: txOut: \(redacting: txOut.publicKey.data)")
                return .success((outputResult.index, (txOut, membershipProof)))
            case .doesNotExist:
                logger.info("FAILURE: outOfBounds with " +
                    "blockCount: \(response.numBlocks), " +
                    "ledgerTxOutCount: \(response.globalTxoCount)")
                return .failure(.outOfBounds(
                    blockCount: response.numBlocks,
                    ledgerTxOutCount: response.globalTxoCount))
            case .outputDatabaseError, .intentionallyUnused, .UNRECOGNIZED:
                logger.info("FAILURE: invalidServerResponse")
                return .failure(.connectionError(.invalidServerResponse(
                    "Fog MerkleProof result error: \(outputResult.resultCodeEnum), response: " +
                    "\(response)")))
            }
        }.collectResult().map {
            Dictionary($0, uniquingKeysWith: { key1, _ in key1 })
        }
    }
}
