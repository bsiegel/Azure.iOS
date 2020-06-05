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

import Foundation
import os.log

/// Protocol which allows clients to customize how they work with Paged Collections.
public protocol PageableClient: PipelineClient {
    // MARK: Required Methods

    func continuationUrl(forRequestUrl requestUrl: URL, withContinuationToken token: String) -> URL?
}

/// Defines the property keys used to conform to the Azure paging design.
public struct PagedCodingKeys {
    // MARK: Properties

    public let items: String
    public let xmlItemName: String?
    public let continuationToken: String

    // MARK: Initializers

    public init(
        items: String = "items",
        continuationToken: String = "continuationToken",
        xmlItemName xmlName: String? = nil
    ) {
        self.items = items
        self.continuationToken = continuationToken
        self.xmlItemName = xmlName
    }

    // MARK: Internal Methods

    internal func items(fromJson json: [String: Any]) -> [Any]? {
        var results: [Any]?
        let components = items.components(separatedBy: ".")
        var current = json
        for component in components {
            guard let temp = current[component] else { return nil }
            if let tempArray = temp as? [Any] {
                guard results == nil else { return nil }
                results = tempArray
            } else if let tempJson = temp as? [String: Any] {
                current = tempJson
            }
        }
        return results
    }

    internal func continuationToken(fromJson json: [String: Any]) -> String? {
        var result: String?
        let components = continuationToken.components(separatedBy: ".")
        var current = json
        for component in components {
            guard let temp = current[component] else { return nil }
            if let tempString = temp as? String {
                guard result == nil else { return nil }
                result = tempString
            } else if let tempJson = temp as? [String: Any] {
                current = tempJson
            }
        }
        return result
    }
}

/// A collection that fetches paged results in a lazy fashion.
public class PagedCollection<Element: Codable> {
    // MARK: Properties

    /// Returns the current running list of items.
    public var items: [Element]? {
        return _items
    }

    /// Returns the subset of items that corresponds to the current page.
    public var pageItems: [Element]? {
        guard let range = pageRange else { return nil }
        guard let slice = _items?[range] else { return nil }
        return Array(slice)
    }

    /// Returns the count of items that have been retrieved so far. There may
    /// be additional results, not yet fetched.
    public var underestimatedCount: Int {
        return items?.count ?? 0
    }

    /// Returns true if there are no more results to fetch.
    public var isExhausted: Bool {
        return continuationToken == nil
    }

    /// Returns a `Sequence` that can be used to iterate through this `PagedCollection` synchronously.
    public lazy var syncCollection = PagedCollectionSequence(self)

    private var _items: [Element]?


    private var pageRange: Range<Int>?

    /// The continuation token used to fetch the next page of results.
    internal var continuationToken: String?

    /// The headers that accompanied the orignal request. Used as the basis for subsequent paged requests.
    private var requestHeaders: HTTPHeaders!

    /// An index which tracks the next item to be returned when using the nextItem method.
    fileprivate var iteratorIndex: Int = 0

    /// A reference to the configured client that created the PagedCollection. Needed to make follow-up
    /// calls to retrieve additional pages.
    private let client: PageableClient

    /// The JSON decoder used to deserialze the JSON payload into the appropriate models.
    private let decoder: JSONDecoder

    /// Key values needed to deserialize the service response into items and a continuation token.
    private let codingKeys: PagedCodingKeys

    /// The initial request URL
    private var requestUrl: URL

    // MARK: Initializers

    public init(
        client: PageableClient,
        request: HTTPRequest,
        data: Data?,
        codingKeys: PagedCodingKeys? = nil,
        decoder: JSONDecoder? = nil
    ) throws {
        let noDataError = HTTPResponseError.decode("Response data expected but not found.")
        guard let data = data else { throw noDataError }
        self.client = client
        self.decoder = decoder ?? JSONDecoder()
        self.codingKeys = codingKeys ?? PagedCodingKeys()
        self.requestHeaders = request.headers
        self.requestUrl = request.url
        try update(with: data)
    }

    // MARK: Public Methods

    public func forEachItem(_ body: @escaping (Element) throws -> Bool) throws {
        var moveNext = true

        try forEachPage { items in
            while moveNext {
                if self.iteratorIndex < items.count {
                    let item = items[self.iteratorIndex]
                    self.iteratorIndex += 1
                    moveNext = try body(item)
                } else {
                    self.iteratorIndex = 0
                    break
                }
            }
            return moveNext
        }
    }

    public func forEachPage(_ body: @escaping ([Element]) throws -> Bool) throws {
        guard let items = pageItems else { return }
        var moveNext = try body(items)
        var pageError: Error?

        while moveNext, pageError == nil {
            nextPage { result in
                switch result {
                case let .failure(error):
                    pageError = error
                case let .success(newPage):
                    if let items = newPage {
                        do {
                            moveNext = try body(items)
                        } catch {
                            pageError = error
                        }
                    } else {
                        moveNext = false
                    }
                }
            }
        }

        if let pageError = pageError {
            throw pageError
        }
    }

    /// Retrieves the next page of results asynchronously.
    public func nextPage(then completion: @escaping (Result<[Element], Error>) -> Void) {
        // exit if there is no valid continuation token
        guard let continuationToken = continuationToken,
            continuationToken != "" else {
            // don't call the completion block at all if the paged collection is exhausted
            return
        }

        client.logger.info(String(format: "Fetching next page with: %@", continuationToken))
        guard let url = client.continuationUrl(forRequestUrl: requestUrl, withContinuationToken: continuationToken)
        else { return }
        var context: PipelineContext?
        if let xmlType = Element.self as? XMLModel.Type {
            let xmlMap = XMLMap(withPagedCodingKeys: codingKeys, innerType: xmlType)
            context = PipelineContext.of(keyValues: [
                ContextKey.xmlMap.rawValue: xmlMap as AnyObject
            ])
        }
        guard let request = try? HTTPRequest(method: .get, url: url, headers: requestHeaders) else { return }
        client.request(request, context: context) { result, _ in
            var returnError: Error?
            switch result {
            case let .failure(error):
                returnError = error
            case let .success(data):
                do {
                    try self.update(with: data)
                } catch {
                    returnError = error
                }
            }
            if let returnError = returnError {
                DispatchQueue.main.async {
                    completion(.failure(returnError))
                }
                return
            }
            self.iteratorIndex = 0
            if let pageItems = self.pageItems {
                DispatchQueue.main.async {
                    completion(.success(pageItems))
                }
            }
        }
    }

    /// Retrieves the next item in the collection, automatically fetching new pages when needed.
    public func nextItem(then completion: @escaping (Result<Element, Error>) -> Void) {
        guard let pageItems = pageItems else {
            // do not call the completion handler if there is no data
            return
        }
        if iteratorIndex >= pageItems.count {
            nextPage { result in
                switch result {
                case let .failure(error):
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                case let .success(newPage):
                    // since we return the first new item, the next iteration should start with the second item.
                    self.iteratorIndex = 1
                    DispatchQueue.main.async {
                        completion(.success(newPage[0]))
                    }
                }
            }
        } else {
            if let item = self.pageItems?[iteratorIndex] {
                iteratorIndex += 1
                DispatchQueue.main.async {
                    completion(.success(item))
                }
            }
        }
    }

    // MARK: Private Methods

    /// Deserializes the JSON payload to append the new items, update tracking of the "current page" of items
    /// and reset the per page iterator.
    private func update(with data: Data?) throws {
        let noDataError = HTTPResponseError.decode("Response data expected but not found.")
        guard let data = data else { throw noDataError }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw noDataError }
        let codingKeys = self.codingKeys
        let notPagedError = HTTPResponseError.decode("Paged response expected but not found.")
        guard let itemJson = codingKeys.items(fromJson: json) else { throw notPagedError }
        continuationToken = codingKeys.continuationToken(fromJson: json)

        let itemData = try JSONSerialization.data(withJSONObject: itemJson)
        let newItems = try decoder.decode([Element].self, from: itemData)
        if let currentItems = _items {
            // append rather than throw away old items
            pageRange = currentItems.count ..< (currentItems.count + newItems.count)
            _items = currentItems + newItems
        } else {
            _items = newItems
            pageRange = 0 ..< newItems.count
        }
    }
}

public struct PagedCollectionSequence<Element: Codable>: Sequence {
    private let collection: PagedCollection<Element>

    fileprivate init(_ collection: PagedCollection<Element>) {
        self.collection = collection
    }

    public func makeIterator() -> PagedCollectionIterator<Element> {
        return PagedCollectionIterator(collection)
    }
}

public struct PagedCollectionIterator<Element: Codable>: IteratorProtocol {
    private let collection: PagedCollection<Element>

    fileprivate init(_ collection: PagedCollection<Element>) {
        self.collection = collection
    }

    public func next() -> Element? {
        guard let pageItems = collection.pageItems else { return nil }
        var moreData = true

        if collection.iteratorIndex >= pageItems.count {
            let syncGroup = DispatchGroup()
            syncGroup.enter()
            collection.nextPage { result in
                if case let .success(newPage) = result {
                    self.collection.iteratorIndex = 0
                    if newPage == nil {
                        moreData = false
                    }
                }
                syncGroup.leave()
            }
            syncGroup.wait()
        }

        if moreData, let item = collection.pageItems?[collection.iteratorIndex] {
            collection.iteratorIndex += 1
            return item
        } else {
            collection.iteratorIndex = 0
            return nil
        }
    }
}
