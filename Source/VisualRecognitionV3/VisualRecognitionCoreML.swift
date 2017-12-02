/**
 * Copyright IBM Corporation 2016-2017
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Foundation
import CoreML
import Vision

@available(iOS 11.0, macOS 10.13, tvOS 11.0, watchOS 4.0, *)
extension VisualRecognition {
    
    /**
     Classify an image with CoreML, given a passed model. On failure or low confidence, fallback to Watson VR cloud service
     
     - parameter image: The image as NSData
     - parameter owners: A list of the classifiers to run. Acceptable values are "IBM" and "me".
     - parameter classifierIDs: A list of the classifier ids to use. "default" is the id of the
     built-in classifier.
     - parameter threshold: The minimum score a class must have to be displayed in the response.
     - parameter language: The language of the output class names. Can be "en" (English), "es"
     (Spanish), "ar" (Arabic), or "ja" (Japanese). Classes for which no translation is available
     are omitted.
     - parameter failure: A function executed if an error occurs.
     - parameter success: A function executed with the image classifications.
     */
    public func classifyLocally(
        image: UIImage,
        owners: [String]? = nil,
        classifierIDs: [String]? = nil,
        threshold: Double? = nil,
        language: String? = nil,
        failure: ((Error) -> Void)? = nil,
        success: @escaping (ClassifiedImages) -> Void)
    {
        // handle multiple local classifiers
        var allResults: [[String: Any]] = []
        var allRequests: [VNCoreMLRequest] = []
        let dispatchGroup = DispatchGroup()
        
        // default classifier if not specified
        // convert UIImage to Data
        guard let image = UIImagePNGRepresentation(image) else {
            let description = "Failed to convert image from UIImage to Data."
            let userInfo = [NSLocalizedDescriptionKey: description]
            let error = NSError(domain: self.domain, code: 0, userInfo: userInfo)
            failure?(error)
            return
        }
        let classifierIDs = classifierIDs ?? ["default"]
        
        // setup requests for each classifier id
        for cid in classifierIDs {
            
            // get model if available
            guard let model = getCoreMLModelLocally(classifierID: cid) else {
                continue
            }
            
            // cast to vision model
            guard let vrModel = try? VNCoreMLModel(for: model) else {
                print("Could not convert MLModel to VNCoreMLModel")
                continue
            }

            dispatchGroup.enter()
            
            // define classifier specific request and callback
            let req = VNCoreMLRequest(model: vrModel, completionHandler: {
                (request, error) in
                
                // get coreml results
                guard let res = request.results else {
                    print( "Unable to classify image.\n\(error!.localizedDescription)" )
                    dispatchGroup.leave()
                    return
                }
                var classifications = res as! [VNClassificationObservation]
                classifications = classifications.filter({$0.confidence > 0.01}) // filter out very low confidence
                
                // parse scores to form class models
                var scores = [[String: Any]]()
                for c in classifications {
                    let tempScore: [String: Any] = [
                        "class" : c.identifier,
                        "score" : Double( c.confidence )
                    ]
                    scores.append(tempScore)
                }
                
                // get metadata
                var name = ""
                var cid = ""
                if let meta = model.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey], let metaDict = meta as? [String: String] {
                    name = metaDict["name"] ?? ""
                    cid = metaDict["classifier_id"] ?? ""
                }
                
                // form classifier model
                let tempClassifier: [String: Any] = [
                    "name": name,
                    "classifier_id": cid,
                    "classes" : scores
                ]
                allResults.append(tempClassifier)
                
                dispatchGroup.leave()
            })
            
            req.imageCropAndScaleOption = .scaleFill // This seems wrong, but yields results in line with vision demo
            
            allRequests.append(req)
        }

        // do requests with handler in background
        for req in allRequests {
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(data: image)
                do {
                    try handler.perform([req])
                } catch {
                    print("Failed to perform classification.\n\(error.localizedDescription)")
                }
            }
        }

        // wait until all classifiers have returned
        dispatchGroup.notify(queue: DispatchQueue.main, execute: {
            
            // form image model
            let bodyIm: [String: Any] = [
                "source_url" : "",
                "resolved_url" : "",
                "image": "",
                "error": "",
                "classifiers": allResults
            ]
            
            // form overall results model
            let body: [String: Any] = [
                "images": [bodyIm],
                "warning": []
            ]
            
            // convert results to sdk vision models
            do {
                let converted = try ClassifiedImages( json: JSONWrapper(dictionary: body) )
                success( converted )
                return
            } catch {
                failure?( error )
                return
            }
        })
    }
    
    /**
     Update the local CoreML model by pulling down the latest available version from the IBM cloud.
     
     - parameter classifierID: The classifier id to update
     - parameter apiKey: TEMPORARY param needed to access solution kit server
     - parameter failure: A function executed if an error occurs.
     - parameter success: A function executed with the image classifications.
     */
    public func updateCoreMLModelLocally(
        classifierID: String,
        apiKey: String,
        failure: ((Error) -> Void)? = nil,
        success: (() -> Void)? = nil)
    {
        // setup urls and filepaths
        let baseUrl = "http://solution-kit-dev.mybluemix.net/api/v1.0/classifiers/"
        let urlString = baseUrl + classifierID + "/model"
        let modelFileName = classifierID + ".mlmodelc"
        let tempFileName = "temp_" + UUID().uuidString + ".mlmodel"
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("Could not get application support directory")
            return
        }
        let tempPath = appSupportDir.appendingPathComponent(tempFileName)
        var modelPath = appSupportDir.appendingPathComponent(modelFileName)

        // setup request
        guard let requestUrl = URL(string: urlString) else { return }
        var request = URLRequest(url:requestUrl)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        
        let task = URLSession.shared.dataTask(with: request) {
            (data, response, error) in
            
            if let error = error {
                print(error)
                failure?(error)
                return
            }
            
            guard let usableData = data  else {
                print("No usable data in response")
                return
            }
            
            // store model spec to temp location
            try? FileManager.default.removeItem(at: tempPath)
            let saveSuccess = FileManager.default.createFile(atPath: tempPath.path, contents: usableData, attributes: nil)
            print("New model spec was saved to file: \(saveSuccess)")
            
            // compile spec and write to final location
            guard let compiledPath = try? MLModel.compileModel(at: tempPath) else {
                print("Error compiling new model")
                return
            }
            try? FileManager.default.removeItem(at: modelPath)
            try? FileManager.default.copyItem(at: compiledPath, to: modelPath)
            
            // exclude from backup
            var resourceVals = URLResourceValues()
            resourceVals.isExcludedFromBackup = true
            try? modelPath.setResourceValues(resourceVals)
            
            print("new Model compiled for classifier: " + classifierID)
            
            // cleanup
            try? FileManager.default.removeItem(at: tempPath)
            
            success?()
        }
        task.resume()
    }
    
    /**
     Access the local CoreML model if available in filesystem.
     
     - parameter classifierID: The classifier id to update
     - parameter failure: A function executed if an error occurs. (Needed?)
     - parameter success: A function executed with the image classifications. (Needed?)
     */
    public func getCoreMLModelLocally(
        classifierID: String)
        -> MLModel?
    {
        // form expected path to model
        let modelFileName = classifierID + ".mlmodelc"
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("Could not get application support directory")
            return nil
        }
        let modelPath = appSupportDir.appendingPathComponent(modelFileName)
        
        // check if available
        if !FileManager.default.fileExists(atPath: modelPath.path) {
            print("No model available for classifier: " + classifierID)
            return nil
        }
        
        // load and return
        guard let model = try? MLModel(contentsOf: modelPath) else {
            print("Could not create CoreML Model")
            return nil
        }
        
        return model
    }

    /**
     Downloads a CoreML model to the local file system.

     - parameter classifierId: The classifierId of the requested model.
     - parameter failure: A function executed if an error occurs.
     - parameter success: A function executed with the URL of the compiled CoreML model.
     */
    func downloadClassifier(
        classifierId: String,
        failure: ((Error) -> Void)? = nil,
        success: @escaping (URL) -> Void)
    {
        // construct query parameters
        var queryParameters = [URLQueryItem]()
        queryParameters.append(URLQueryItem(name: "api_key", value: apiKey))
        queryParameters.append(URLQueryItem(name: "version", value: version))

        // construct REST request
        let request = RestRequest(
            method: "GET",
            url: serviceURL + "/v3/classifiers/\(classifierId)/core_ml_model",
            credentials: .apiKey,
            headerParameters: defaultHeaders,
            queryItems: queryParameters
        )

        // locate downloads directory
        let fileManager = FileManager.default
        let downloadDirectories = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask)
        guard let downloads = downloadDirectories.first else {
            let description = "Cannot locate downloads directory."
            let userInfo = [NSLocalizedDescriptionKey: description]
            let error = NSError(domain: self.domain, code: 0, userInfo: userInfo)
            failure?(error)
            return
        }

        // locate application support directory
        let applicationSupportDirectories = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let applicationSupport = applicationSupportDirectories.first else {
            let description = "Cannot locate application support directory."
            let userInfo = [NSLocalizedDescriptionKey: description]
            let error = NSError(domain: self.domain, code: 0, userInfo: userInfo)
            failure?(error)
            return
        }

        // specify file destinations
        let sourceModelURL = downloads.appendingPathComponent(classifierId + ".mlmodel")
        var compiledModelURL = applicationSupport.appendingPathComponent(classifierId + ".mlmodelc")

        // execute REST request
        request.download(to: sourceModelURL) { response, error in
            guard error == nil else {
                failure?(error!)
                return
            }

            guard let statusCode = response?.statusCode else {
                let description = "Did not receive response."
                let userInfo = [NSLocalizedDescriptionKey: description]
                let error = NSError(domain: self.domain, code: 0, userInfo: userInfo)
                failure?(error)
                return
            }

            guard (200..<300).contains(statusCode) else {
                let description = "Status code was not acceptable: \(statusCode)."
                let userInfo = [NSLocalizedDescriptionKey: description]
                let error = NSError(domain: self.domain, code: statusCode, userInfo: userInfo)
                failure?(error)
                return
            }

            // compile model from source
            let compiledModelTemporaryURL: URL
            do {
                compiledModelTemporaryURL = try MLModel.compileModel(at: sourceModelURL)
            } catch {
                let description = "Could not compile Core ML model from source: \(error)"
                let userInfo = [NSLocalizedDescriptionKey: description]
                let error = NSError(domain: self.domain, code: 0, userInfo: userInfo)
                failure?(error)
                return
            }

            // move compiled model and clean up files
            do {
                if fileManager.fileExists(atPath: compiledModelURL.absoluteString) {
                    try fileManager.removeItem(at: compiledModelURL)
                }
                try fileManager.copyItem(at: compiledModelTemporaryURL, to: compiledModelURL)
                try fileManager.removeItem(at: compiledModelTemporaryURL)
                try fileManager.removeItem(at: sourceModelURL)
            } catch {
                let description = "Failed to move compiled model and clean up files: \(error)"
                let userInfo = [NSLocalizedDescriptionKey: description]
                let error = NSError(domain: self.domain, code: 0, userInfo: userInfo)
                failure?(error)
                return
            }

            // exclude compiled model from device backups
            var urlResourceValues = URLResourceValues()
            urlResourceValues.isExcludedFromBackup = true
            do {
                try compiledModelURL.setResourceValues(urlResourceValues)
            } catch {
                let description = "Could not exclude compiled model from backup: \(error)"
                let userInfo = [NSLocalizedDescriptionKey: description]
                let error = NSError(domain: self.domain, code: 0, userInfo: userInfo)
                failure?(error)
            }

            success(compiledModelURL)
        }
    }
}
