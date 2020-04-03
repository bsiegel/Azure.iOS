// --------------------------------------------------------------------------
//
// Copyright (c) Microsoft Corporation. All rights reserved.
//
// The MIT License (MIT)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the ""Software""), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// --------------------------------------------------------------------------

import AzureCore
import CoreData

// MARK: Protocols

internal protocol TransferManager: ResumableOperationQueueDelegate {
    // MARK: Properties

    var reachability: ReachabilityManager? { get }
    var persistentContainer: NSPersistentContainer? { get }
    var logger: ClientLogger { get set }
    var delegate: TransferDelegate? { get set }

    // MARK: Storage Methods

    // TODO: Uplevel the relelvant func signatures into TM protocol once reviewed
    // func upload(_ url: URL) -> Transferable
    // func download(_ url: URL) -> Transferable
    // func copy(from source: URL, to destination: URL) -> Transferable

    // MARK: Queue Operations

    var count: Int { get }
    subscript(_: Int) -> Transfer { get }
    var transfers: [Transfer] { get }

    func add(transfer: Transfer)
    func cancel(transfer: Transfer)
    func cancelAll()
    func pause(transfer: Transfer)
    func pauseAll()
    func remove(transfer: Transfer)
    func removeAll()
    func resume(transfer: Transfer)
    func resumeAll()
    func loadContext()
    func saveContext()
}

/// A delegate to receive notifications about state changes for all transfers managed by a `StorageBlobClient`.
public protocol TransferDelegate: AnyObject {
    /// A transfer's state has changed, and progress is being reported.
    func transfer(_: Transfer, didUpdateWithState: TransferState, andProgress: TransferProgress?)
    /// A transfer's state has changed, no progress information is available.
    func transfer(_: Transfer, didUpdateWithState: TransferState)
    /// A transfer has failed.
    func transfer(_: Transfer, didFailWithError: Error)
    /// A transfer has completed.
    func transferDidComplete(_: Transfer)
    /// Method to return a `PipelineClient` that can be used to restart a transfer.
    func client(forRestorationId restorationId: String) -> PipelineClient?
    /// Method to return an `AzureOptions` object that can be used to restart a transfer.
    func options(forRestorationId restorationId: String) -> AzureOptions?
}

// MARK: Extensions

public extension Array where Element == Transfer {
    /// Retrieve all upload transfers where the source matches the provided source URL.
    /// - Parameters:
    ///   - sourceURL: The URL to a file on this device.
    func from(_ sourceURL: URL) -> [Transfer] {
        return filter { transfer in
            guard let transfer = transfer as? BlobTransfer else { return false }
            return transfer.transferType == .upload && transfer.source == sourceURL
        }
    }

    /// Retrieve all download transfers where the source container and blob match the provided parameters.
    /// - Parameters:
    ///   - container: The name of the container.
    ///   - blob: The name of the blob.
    func from(container: String, blob: String) -> [Transfer] {
        let pathSuffix = "\(container)/\(blob)"
        return filter { transfer in
            guard let transfer = transfer as? BlobTransfer, let source = transfer.source else { return false }
            return transfer.transferType == .download && source.path.hasSuffix(pathSuffix)
        }
    }

    /// Retrieve all download transfers where the destination matches the provided destination URL.
    /// - Parameters:
    ///   - destinationURL: The URL to a file path on this device.
    func to(_ destinationURL: URL) -> [Transfer] {
        return filter { transfer in
            guard let transfer = transfer as? BlobTransfer else { return false }
            return transfer.transferType == .download && transfer.destination == destinationURL
        }
    }

    /// Retrieve all upload transfers where the destination container and blob match the provided parameters.
    /// - Parameters:
    ///   - container: The name of the container.
    ///   - blob: The name of the blob.
    func to(container: String, blob: String) -> [Transfer] {
        let pathSuffix = "\(container)/\(blob)"
        return filter { transfer in
            guard let transfer = transfer as? BlobTransfer, let destination = transfer.destination else { return false }
            return transfer.transferType == .upload && destination.path.hasSuffix(pathSuffix)
        }
    }

    /// Retrieve all transfers of the provided type.
    ///
    /// - Parameters:
    ///   - type: The type of transfers to retrieve.
    func of(type transferType: TransferType) -> [Transfer] {
        return filter { transfer in
            guard let transfer = transfer as? BlobTransfer else { return false }
            return transfer.transferType == transferType
        }
    }

    /// Retrieve a single Transfer object by its id.
    ///
    /// - Parameters:
    ///   - id: The id of the transfer to retrieve.
    func firstWith(id: UUID) -> Transfer? {
        return first { $0.id == id }
    }
}

public extension TransferDelegate {
    /// A transfer's state has changed, no progress information is available.
    func transfer(_ transferParam: Transfer, didUpdateWithState state: TransferState) {
        transfer(transferParam, didUpdateWithState: state, andProgress: nil)
    }
}
