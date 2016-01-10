//
//  Geocore.swift
//  GeocoreKit
//
//  Created by Purbo Mohamad on 4/14/15.
//
//

import Foundation
import Alamofire
import SwiftyJSON
import PromiseKit

struct GeocoreConstants {
    private static let BundleKeyBaseURL = "GeocoreBaseURL"
    private static let BundleKeyProjectID = "GeocoreProjectId"
    private static let HTTPHeaderAccessTokenName = "Geocore-Access-Token"
}

/**
    GeocoreKit error code.

    - InvalidState:            Unexpected internal state. Possibly a bug.
    - InvalidServerResponse:   Unexpected server response. Possibly a bug.
    - UnexpectedResponse:      Unexpected response format. Possibly a bug.
    - ServerError:             Server returns an error.
    - TokenUndefined:          Token is unavailable. Possibly the library is left uninitialized or user is not logged in.
    - UnauthorizedAccess:      Access to the specified resource is forbidden. Possibly the user is not logged in.
    - InvalidParameter:        One of the parameter passed to the API is invalid.
    - NetworkError:            Underlying network library produces an error.
*/
public enum GeocoreError: ErrorType {
    case InvalidState
    case InvalidServerResponse(statusCode: Int)
    case UnexpectedResponse(message: String)
    case ServerError(code: String, message: String)
    case TokenUndefined
    case UnauthorizedAccess
    case InvalidParameter(message: String)
    case NetworkError(error: NSError)
}

public enum GeocoreServerResponse: Int {
    case Unavailable = -1
    case UnexpectedResponse = -2
}

/**
    Representing an object that can be initialized from JSON data.
 */
public protocol GeocoreInitializableFromJSON {
    init(_ json: JSON)
}

/**
    Representing an object that can be serialized to JSON.
*/
public protocol GeocoreSerializableToJSON {
    func toDictionary() -> [String: AnyObject]
}

public protocol GeocoreIdentifiable: GeocoreInitializableFromJSON, GeocoreSerializableToJSON {
    var sid: Int64? { get set }
    var id: String? { get set }
}

/**
    A wrapper for raw JSON value returned by Geocore service.
*/
public class GeocoreGenericResult: GeocoreInitializableFromJSON {
    
    private(set) public var json: JSON
    
    public required init(_ json: JSON) {
        self.json = json
    }
}

/**
    A wrapper for count request returned by Geocore service.
 */
public class GeocoreGenericCountResult: GeocoreInitializableFromJSON {
    
    private(set) public var count: Int?
    
    public required init(_ json: JSON) {
        self.count = json["count"].int
    }
    
}

/**
    Geographical point in WGS84.
 */
public struct GeocorePoint: GeocoreSerializableToJSON, GeocoreInitializableFromJSON {
    
    public var latitude: Float?
    public var longitude: Float?
    
    public init() {
    }
    
    public init(latitude: Float?, longitude: Float?) {
        self.latitude = latitude
        self.longitude = longitude
    }
    
    public init(_ json: JSON) {
        self.latitude = json["latitude"].float
        self.longitude = json["longitude"].float
    }
    
    public func toDictionary() -> [String: AnyObject] {
        if let latitude = self.latitude, longitude = self.longitude {
            return ["latitude": NSNumber(float: latitude), "longitude": NSNumber(float: longitude)]
        } else {
            return [String: AnyObject]()
        }
    }
}

/**
    Representing a result returned by Geocore service.

    - Success: Containing value of the result.
    - Failure: Containing an error.
*/
public enum GeocoreResult<T> {
    case Success(T)
    case Failure(GeocoreError)
    
    public init(_ value: T) {
        self = .Success(value)
    }
    
    public init(_ error: GeocoreError) {
        self = .Failure(error)
    }
    
    public var failed: Bool {
        switch self {
        case .Failure(_):
            return true
        default:
            return false
        }
    }
    
    public var error: GeocoreError? {
        switch self {
        case .Failure(let error):
            return error
        default:
            return nil
        }
    }
    
    public var value: T? {
        switch self {
        case .Success(let value):
            return value
        default:
            return nil
        }
    }
    
    public func propagateTo(fulfill: (T) -> Void, reject: (ErrorType) -> Void) -> Void {
        switch self {
        case .Success(let value):
            fulfill(value)
        case .Failure(let error):
            reject(error)
        }
    }
}

// MARK: -

/**
 *  Main singleton class.
 */
public class Geocore: NSObject {
    
    /// Singleton instance
    public static let sharedInstance = Geocore()
    public static let geocoreDateFormatter = NSDateFormatter.dateFormatterForGeocore()
    
    public private(set) var baseURL: String?
    public private(set) var projectId: String?
    public private(set) var userId: String?
    private var token: String?
    
    private override init() {
        self.baseURL = NSBundle.mainBundle().objectForInfoDictionaryKey(GeocoreConstants.BundleKeyBaseURL) as? String
        self.projectId = NSBundle.mainBundle().objectForInfoDictionaryKey(GeocoreConstants.BundleKeyProjectID) as? String
    }
    
    /**
        Setting up the library.
    
        :param: baseURL   Geocore server endpoint
        :param: projectId Project ID
    
        :returns: Geocore object
    */
    public func setup(baseURL: String, projectId: String) -> Geocore {
        self.baseURL = baseURL;
        self.projectId = projectId;
        return self;
    }
    
    // MARK: Private utilities
    
    private func path(servicePath: String) -> String? {
        if let baseURL = self.baseURL {
            return baseURL + servicePath
        } else {
            return nil
        }
    }
    
    private func mutableURLRequest(method: Alamofire.Method, path: String, token: String) -> NSMutableURLRequest {
        let ret = NSMutableURLRequest(URL: NSURL(string: path)!)
        ret.HTTPMethod = method.rawValue
        ret.setValue(token, forHTTPHeaderField: GeocoreConstants.HTTPHeaderAccessTokenName)
        return ret
    }
    
    private func generateMultipartBoundaryConstant() -> String {
        return NSString(format: "Boundary+%08X%08X", arc4random(), arc4random()) as String
    }
    
    private func multipartURLRequest(method: Alamofire.Method, path: String, token: String, fieldName: String, fileName: String, mimeType: String, fileContents: NSData) -> NSMutableURLRequest {
        
        let mutableURLRequest = self.mutableURLRequest(.POST, path: path, token: token)
        
        let boundaryConstant = self.generateMultipartBoundaryConstant()
        let boundaryStart = "--\(boundaryConstant)\r\n"
        let boundaryEnd = "--\(boundaryConstant)--\r\n"
        let contentDispositionString = "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n"
        let contentTypeString = "Content-Type: \(mimeType)\r\n\r\n"
        
        let requestBodyData : NSMutableData = NSMutableData()
        requestBodyData.appendData(boundaryStart.dataUsingEncoding(NSUTF8StringEncoding)!)
        requestBodyData.appendData(contentDispositionString.dataUsingEncoding(NSUTF8StringEncoding)!)
        requestBodyData.appendData(contentTypeString.dataUsingEncoding(NSUTF8StringEncoding)!)
        requestBodyData.appendData(fileContents)
        requestBodyData.appendData("\r\n".dataUsingEncoding(NSUTF8StringEncoding)!)
        requestBodyData.appendData(boundaryEnd.dataUsingEncoding(NSUTF8StringEncoding)!)
        
        mutableURLRequest.setValue("multipart/form-data; boundary=\(boundaryConstant)", forHTTPHeaderField: "Content-Type")
        mutableURLRequest.HTTPBody = requestBodyData
        
        return mutableURLRequest
    }
    
    private func parameterEncoding(method: Alamofire.Method) -> Alamofire.ParameterEncoding {
        switch method {
        case .GET, .HEAD, .DELETE:
            return .URL
        default:
            return .JSON
        }
    }
    
    // from Alamofire internal
    func escape(string: String) -> String {
        let legalURLCharactersToBeEscaped: CFStringRef = ":&=;+!@#$()',*"
        return CFURLCreateStringByAddingPercentEscapes(nil, string, nil, legalURLCharactersToBeEscaped, CFStringBuiltInEncodings.UTF8.rawValue) as String
    }
    
    // from Alamofire internal
    func queryComponents(key: String, _ value: AnyObject) -> [(String, String)] {
        var components: [(String, String)] = []
        if let dictionary = value as? [String: AnyObject] {
            for (nestedKey, value) in dictionary {
                components += queryComponents("\(key)[\(nestedKey)]", value)
            }
        } else if let array = value as? [AnyObject] {
            for value in array {
                components += queryComponents("\(key)[]", value)
            }
        } else {
            components.appendContentsOf([(escape(key), escape("\(value)"))])
        }
        
        return components
    }
    
    private func multipartInfo(body: [String: AnyObject]? = nil) -> (fileContents: NSData, fileName: String, fieldName: String, mimeType: String)? {
        if let fileContents = body?["$fileContents"] as? NSData {
            if let fileName = body?["$fileName"] as? String, fieldName = body?["$fieldName"] as? String, mimeType = body?["$mimeType"] as? String {
                return (fileContents, fileName, fieldName, mimeType)
            }
        }
        return nil
    }
    
    private func validateRequestBody(body: [String: AnyObject]? = nil) -> Bool {
        if let _ = body?["$fileContents"] as? NSData {
            // uploading file, make sure all required parameters are specified as well
            if let _ = body?["$fileName"] as? String, _ = body?["$fieldName"] as? String, _ = body?["$mimeType"] as? String {
                return true
            } else {
                return false
            }
        } else {
            return true
        }
    }
    
    private func buildQueryParameter(mutableURLRequest: NSMutableURLRequest, parameters: [String: AnyObject]?) -> NSURL? {
        
        if let someParameters = parameters {
            // from Alamofire internal
            func query(parameters: [String: AnyObject]) -> String {
                var components: [(String, String)] = []
                for key in Array(parameters.keys).sort(<) {
                    let value = parameters[key]!
                    components += queryComponents(key, value)
                }
                
                return (components.map { "\($0)=\($1)" } as [String]).joinWithSeparator("&")
            }
            
            // since we have both non-nil parameters and body,
            // the parameters should go to URL query parameters,
            // and the body should go to HTTP body
            if let URLComponents = NSURLComponents(URL: mutableURLRequest.URL!, resolvingAgainstBaseURL: false) {
                URLComponents.percentEncodedQuery = (URLComponents.percentEncodedQuery != nil ? URLComponents.percentEncodedQuery! + "&" : "") + query(someParameters)
                return URLComponents.URL
            }
        }
        
        return nil
    }
    
    /**
        Build and customize Alamofire request with Geocore token and optional parameter/body specification.
    
        :param: method Alamofire Method enum representing HTTP request method
        :param: parameters parameters to be used as URL query parameters (for GET, DELETE) or POST parameters in the body except is body parameter is not nil. For POST, ff body parameter is not nil it will be encoded as POST body (JSON or multipart) and parameters will become URL query parameters.
        :param: body POST JSON or multipart content. For multipart content, the body will have to contain following key-values: ("$fileContents" => NSData), ("$fileName" => String), ("$fieldName" => String), ("$mimeType" => String)
    
        :returns: function that given a URL path will generate appropriate Alamofire Request object.
    */
    private func requestBuilder(method: Alamofire.Method, parameters: [String: AnyObject]? = nil, body: [String: AnyObject]? = nil) -> ((String) -> Request)? {
        
        if !self.validateRequestBody(body) {
            return nil
        }
        
        if let token = self.token {
            // if token is available (user already logged-in), use NSMutableURLRequest to customize HTTP header
            return { (path: String) -> Request in
                
                // NSMutableURLRequest with customized HTTP header
                var mutableURLRequest: NSMutableURLRequest
                
                if let multipartInfo = self.multipartInfo(body) {
                    mutableURLRequest = self.multipartURLRequest(method, path: path, token: token, fieldName: multipartInfo.fieldName, fileName: multipartInfo.fileName, mimeType: multipartInfo.mimeType, fileContents: multipartInfo.fileContents)
                } else {
                    mutableURLRequest = self.mutableURLRequest(method, path: path, token: token)
                }
                
                let parameterEncoding = self.parameterEncoding(method)
                
                if let someBody = body {
                    // pass parameters as query parameters, body to be processed by Alamofire
                    if let url = self.buildQueryParameter(mutableURLRequest, parameters: parameters) {
                        mutableURLRequest.URL = url
                    }
                    
                    if someBody.isEmpty {
                        switch parameterEncoding {
                        case .JSON:
                            mutableURLRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            mutableURLRequest.HTTPBody = try! NSJSONSerialization.dataWithJSONObject(someBody, options: NSJSONWritingOptions())
                        default:
                            break
                        }
                    }
                    
                    return Alamofire.request(parameterEncoding.encode(mutableURLRequest, parameters: someBody).0)
                } else {
                    // set parameters according to standard Alamofire's encode processing
                    return Alamofire.request(parameterEncoding.encode(mutableURLRequest, parameters: parameters).0)
                }
            }
        } else {
            if let someBody = body {
                // no token but with body & parameters separate
                return { (path: String) -> Request in
                    let mutableURLRequest = NSMutableURLRequest(URL: NSURL(string: path)!)
                    mutableURLRequest.HTTPMethod = method.rawValue
                    if let url = self.buildQueryParameter(mutableURLRequest, parameters: parameters) {
                        mutableURLRequest.URL = url
                    }
                    return Alamofire.request(self.parameterEncoding(method).encode(mutableURLRequest, parameters: someBody).0)
                }
            } else {
                // otherwise do a normal Alamofire request
                return { (path: String) -> Request in Alamofire.request(method, path, parameters: parameters) }
            }
        }
    }
    
    /**
        The ultimate generic request method.
    
        :param: path Path relative to base API URL.
        :param: requestBuilder Function to be used to create Alamofire request.
        :param: onSuccess What to do when the server successfully returned a result.
        :param: onError What to do when there is an error.
     */
    private func request(
            path: String,
            requestBuilder: (String) -> Request,
            onSuccess: (JSON) -> Void,
            onError: (GeocoreError) -> Void) {
                
                requestBuilder(self.path(path)!).response { (_, res, optData, optError) -> Void in
                    if let error = optError {
                        print("[ERROR] \(error)")
                        onError(.NetworkError(error: error))
                    } else if let data = optData {
                        if let statusCode = res?.statusCode {
                            switch statusCode {
                            case 200:
                                let json = JSON(data: data)
                                if let status = json["status"].string {
                                    if status == "success" {
                                        onSuccess(json["result"])
                                    } else {
                                        onError(.ServerError(
                                            code: json["code"].string ?? "",
                                            message: json["message"].string ?? ""))
                                    }
                                } else {
                                    onError(.InvalidServerResponse(
                                        statusCode: GeocoreServerResponse.UnexpectedResponse.rawValue))
                                }
                            case 403:
                                onError(.UnauthorizedAccess)
                            default:
                                onError(.InvalidServerResponse(
                                    statusCode: statusCode))
                            }
                        } else {
                            onError(.InvalidServerResponse(
                                statusCode: GeocoreServerResponse.Unavailable.rawValue))
                        }
                    }
                }
    }
    
    /**
        Request resulting a single result of type T.
     */
    func request<T: GeocoreInitializableFromJSON>(path: String, requestBuilder optRequestBuilder: ((String) -> Request)?, callback: (GeocoreResult<T>) -> Void) {
        if let requestBuilder = optRequestBuilder {
            self.request(path, requestBuilder: requestBuilder,
                onSuccess: { json -> Void in callback(GeocoreResult(T(json))) },
                onError: { error -> Void in callback(.Failure(error)) })
        } else {
            callback(.Failure(.InvalidParameter(message: "Unable to build request, likely because of unexpected parameters.")))
        }
    }
    
    /**
        Request resulting multiple result in an array of objects of type T
     */
    func request<T: GeocoreInitializableFromJSON>(path: String, requestBuilder optRequestBuilder: ((String) -> Request)?, callback: (GeocoreResult<[T]>) -> Void) {
        if let requestBuilder = optRequestBuilder {
            self.request(path, requestBuilder: requestBuilder,
                onSuccess: { json -> Void in
                    if let result = json.array {
                        callback(GeocoreResult(result.map { T($0) }))
                    } else {
                        callback(GeocoreResult([]))
                    }
                },
                onError: { error -> Void in callback(.Failure(error)) })
        } else {
            callback(.Failure(.InvalidParameter(message: "Unable to build request, likely because of unexpected parameters.")))
        }
    }
    
    // MARK: HTTP methods: GET, POST, DELETE, PUT
    
    /**
        Do an HTTP GET request expecting one result of type T
     */
    func GET<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil, callback: (GeocoreResult<T>) -> Void) {
        self.request(path, requestBuilder: self.requestBuilder(.GET, parameters: parameters), callback: callback)
    }
    
    /**
        Promise a single result of type T from an HTTP GET request.
     */
    func promisedGET<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil) -> Promise<T> {
        return Promise { (fulfill, reject) in
            self.GET(path, parameters: parameters) { (result: GeocoreResult<T>) -> Void in
                result.propagateTo(fulfill, reject: reject)
            }
        }
    }
    
    /**
        Do an HTTP GET request expecting an multiple result in an array of objects of type T
     */
    func GET<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil, callback: (GeocoreResult<[T]>) -> Void) {
        self.request(path, requestBuilder: self.requestBuilder(.GET, parameters: parameters), callback: callback)
    }
    
    /**
        Promise multiple result of type T from an HTTP GET request.
     */
    func promisedGET<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil) -> Promise<[T]> {
        return Promise { (fulfill, reject) in
            self.GET(path, parameters: parameters) { (result: GeocoreResult<[T]>) -> Void in
                result.propagateTo(fulfill, reject: reject)
            }
        }
    }
    
    /**
        Do an HTTP POST request expecting one result of type T
     */
    func POST<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil, body: [String: AnyObject]? = nil, callback: (GeocoreResult<T>) -> Void) {
        self.request(path, requestBuilder: self.requestBuilder(.POST, parameters: parameters, body: body), callback: callback)
    }
    
    /**
        Do an HTTP POST request expecting an multiple result in an array of objects of type T
     */
    func POST<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil, body: [String: AnyObject]? = nil, callback: (GeocoreResult<[T]>) -> Void) {
        self.request(path, requestBuilder: self.requestBuilder(.POST, parameters: parameters, body: body), callback: callback)
    }
    
    func uploadPOST<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil, fieldName: String, fileName: String, mimeType: String, fileContents: NSData, callback: (GeocoreResult<T>) -> Void) {
        self.POST(path, parameters: parameters, body: ["$fileContents": fileContents, "$fileName": fileName, "$fieldName": fieldName, "$mimeType": mimeType], callback: callback)
    }
    
    /**
        Promise a single result of type T from an HTTP POST request.
     */
    func promisedPOST<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil, body: [String: AnyObject]? = nil) -> Promise<T> {
        return Promise { (fulfill, reject) in
            self.POST(path, parameters: parameters, body: body) { (result: GeocoreResult<T>) -> Void in
                result.propagateTo(fulfill, reject: reject)
            }
        }
    }
    
    /**
     Promise multiple results of type T from an HTTP POST request.
     */
    func promisedPOST<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil, body: [String: AnyObject]? = nil) -> Promise<[T]> {
        return Promise { (fulfill, reject) in
            self.POST(path, parameters: parameters, body: body) { (result: GeocoreResult<[T]>) -> Void in
                result.propagateTo(fulfill, reject: reject)
            }
        }
    }
    
    func promisedUploadPOST<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil, fieldName: String, fileName: String, mimeType: String, fileContents: NSData) -> Promise<T> {
        return self.promisedPOST(path, parameters: parameters, body: ["$fileContents": fileContents, "$fileName": fileName, "$fieldName": fieldName, "$mimeType": mimeType])
    }
    
    /**
        Do an HTTP DELETE request expecting one result of type T
     */
    func DELETE<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil, callback: (GeocoreResult<T>) -> Void) {
        self.request(path, requestBuilder: self.requestBuilder(.DELETE, parameters: parameters), callback: callback)
    }
    
    /**
        Promise a single result of type T from an HTTP DELETE request.
     */
    func promisedDELETE<T: GeocoreInitializableFromJSON>(path: String, parameters: [String: AnyObject]? = nil) -> Promise<T> {
        return Promise { (fulfill, reject) in
            self.DELETE(path, parameters: parameters) { (result: GeocoreResult<T>) -> Void in
                result.propagateTo(fulfill, reject: reject)
            }
        }
    }
    
    // MARK: User management methods (callback version)
    
    /**
    Login to Geocore with callback.
    
    - parameter userId:   User's ID to be submitted.
    - parameter password: Password for authorizing user.
    - parameter callback: Closure to be called when the token string or an error is returned.
    */
    public func login(userId: String, password: String, callback:(GeocoreResult<String>) -> Void) {
        self.POST("/auth", parameters: ["id": userId, "password": password, "project_id": self.projectId!]) { (result: GeocoreResult<GeocoreGenericResult>) -> Void in
            switch result {
                case .Success(let value):
                    self.token = value.json["token"].string
                    if let token = self.token {
                        self.userId = userId
                        callback(GeocoreResult(token))
                    } else {
                        callback(.Failure(GeocoreError.InvalidState))
                    }
                case .Failure(let error):
                    callback(.Failure(error))
            }
        }
    }
    
    public func loginWithDefaultUser(callback:(GeocoreResult<String>) -> Void) {
        // login using default id & password
        self.login(GeocoreUser.defaultId(), password: GeocoreUser.defaultPassword()) { result in
            switch result {
            case .Success(_):
                callback(result)
            case .Failure(let error):
                // oops! try to register first
                switch error {
                case .ServerError(let code, _):
                    if code == "Auth.0001" {
                        // not registered, register the default user first
                        GeocoreUserOperation().register(GeocoreUser.defaultUser(), callback: { result in
                            switch result {
                            case .Success(_):
                                // successfully registered, now login again
                                self.login(GeocoreUser.defaultId(), password: GeocoreUser.defaultPassword()) { result in
                                    callback(result)
                                }
                            case .Failure(let error):
                                callback(.Failure(error))
                            }
                        });
                    } else {
                        // unexpected error
                        callback(.Failure(error))
                    }
                default:
                    // unexpected error
                    callback(.Failure(error))
                }
            }
        }
    }
    
    // MARK: User management methods (promise version)
    
    /**
        Login to Geocore with promise.
    
        :param: userId   User's ID to be submitted.
        :param: password Password for authorizing user.
    
        :returns: Promise for Geocore Access Token (as String).
     */
    public func login(userId: String, password: String) -> Promise<String> {
        return Promise { (fulfill, reject) in
            self.login(userId, password: password) { result in
                result.propagateTo(fulfill, reject: reject)
            }
        }
    }
    
    public func loginWithDefaultUser() -> Promise<String> {
        return Promise { (fulfill, reject) in
            self.loginWithDefaultUser { result in
                result.propagateTo(fulfill, reject: reject)
            }
        }
    }
    
}

