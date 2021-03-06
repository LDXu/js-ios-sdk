/*
 * Jaspersoft Mobile SDK
 * Copyright (C) 2011 - 2014 Jaspersoft Corporation. All rights reserved.
 * http://community.jaspersoft.com/project/mobile-sdk-ios
 *
 * Unless you have purchased a commercial license agreement from Jaspersoft,
 * the following license terms apply:
 *
 * This program is part of Jaspersoft Mobile SDK for iOS.
 *
 * Jaspersoft Mobile SDK is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Jaspersoft Mobile SDK is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with Jaspersoft Mobile SDK for iOS. If not, see
 * <http://www.gnu.org/licenses/lgpl>.
 */

//
//  JSReportLoader.m
//  Jaspersoft Corporation
//

#import "JSReportLoader.h"
#import "JSRESTBase+JSRESTReport.h"
#import "JSReportExecutionConfiguration.h"
#import "JSReportExecutionResponse.h"
#import "JSExportExecutionResponse.h"

@interface JSReportLoader()
@property (nonatomic, weak, readwrite) JSReport *report;
@property (nonatomic, copy) JSRESTBase *restClient;
@property (nonatomic, assign, readwrite) BOOL isReportInLoadingProcess;

// callbacks
@property (nonatomic, copy) JSReportLoaderCompletionBlock loadPageCompletionBlock;
//
@property (nonatomic, strong) JSExecutionStatus *reportExecutionStatus;
@property (nonatomic, strong) NSMutableDictionary *exportIdsDictionary;
@property (nonatomic, assign) JSReportLoaderOutputResourceType outputResourceType;

// cache
@property (nonatomic, strong) NSMutableDictionary *cachedPages;
@property (nonatomic, strong) JSReportExecutionConfiguration *configuration;

@end

@implementation JSReportLoader
#pragma mark - Lifecycle
- (instancetype)initWithReport:(JSReport *)report restClient:(nonnull JSRESTBase *)restClient{
    self = [super init];
    if (self) {
        self.report = report;
        self.restClient = restClient;
    }
    return self;
}

+ (instancetype)loaderWithReport:(JSReport *)report restClient:(nonnull JSRESTBase *)restClient {
    return [[self alloc] initWithReport:report restClient:restClient];
}

#pragma mark - Custom accessors
- (NSMutableDictionary *)exportIdsDictionary {
    if (!_exportIdsDictionary) {
        _exportIdsDictionary = [NSMutableDictionary dictionary];
    }
    return _exportIdsDictionary;
}

- (JSReportExecutionConfiguration *)configuration {
    if (!_configuration) {
        _configuration = [JSReportExecutionConfiguration viewReportConfigurationWithServerProfile:self.restClient.serverProfile];
    }
    return _configuration;
}

#pragma mark - Public API
- (void)runReportWithPage:(NSInteger)page completion:(JSReportLoaderCompletionBlock)completionBlock; {
    [self clearCachedReportPages];
    [self.report restoreDefaultState];

    self.loadPageCompletionBlock = completionBlock;
    

    [self.report updateCurrentPage:page];
    
    // restore default state of loader
    self.exportIdsDictionary = [@{} mutableCopy];
    self.isReportInLoadingProcess = YES;
    self.outputResourceType = JSReportLoaderOutputResourceType_None;
    
    [self runReportExecution];
}

- (void)fetchPageNumber:(NSInteger)pageNumber withCompletion:(JSReportLoaderCompletionBlock)completionBlock {
    self.loadPageCompletionBlock = completionBlock;
    [self.report updateCurrentPage:pageNumber];
    [self startExportExecutionForPage:pageNumber];
}

- (void)cancel {
    self.loadPageCompletionBlock = nil;
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(makeStatusChecking) object:nil];
    [self.restClient cancelAllRequests];
    
    if ((self.reportExecutionStatus.status == kJS_EXECUTION_STATUS_EXECUTION || self.reportExecutionStatus.status == kJS_EXECUTION_STATUS_QUEUED) && self.report.requestId) {
        [self.restClient cancelReportExecution:self.report.requestId completionBlock:nil];
    }
}

- (void)refreshReportWithCompletion:(void(^)(BOOL success, NSError *error))completion {
    [self runReportWithPage:1 completion:completion];
}

- (void)applyReportParametersWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    [self runReportWithPage:1 completion:completion];
}

- (BOOL) shouldDisplayLoadingView {
    return YES;
}


#pragma mark - Private API

- (void) runReportExecution {
    __weak typeof(self) weakSelf = self;
    [self.restClient runReportExecution:self.report.reportURI
                                  async:self.configuration.asyncExecution
                           outputFormat:self.configuration.outputFormat
                             markupType:(self.needEmbeddableOutput ? JSMarkupTypeEmbeddable : JSMarkupTypeFull)
                            interactive:self.configuration.interactive
                              freshData:self.configuration.freshData
                       saveDataSnapshot:self.configuration.saveDataSnapshot
                       ignorePagination:self.configuration.ignorePagination
                         transformerKey:self.configuration.transformerKey
                                  pages:self.configuration.pagesRange.formattedPagesRange
                      attachmentsPrefix:self.configuration.attachmentsPrefix
                             parameters:self.report.reportParameters
                        completionBlock:^(JSOperationResult *result) {
                            __strong typeof(self) strongSelf = weakSelf;
                            if (result.error) {
                                [strongSelf handleError:result.error withLoadedObjects:result.objects forPage:NSNotFound];
                            } else {
                                
                                JSReportExecutionResponse *executionResponse = [result.objects firstObject];
                                NSString *requestId = executionResponse.requestId;
                                
                                if (requestId) {
                                    [strongSelf.report updateRequestId:requestId];
                                    
                                    if (executionResponse.status.status == kJS_EXECUTION_STATUS_FAILED ||
                                        executionResponse.status.status == kJS_EXECUTION_STATUS_CANCELED) {
                                        NSDictionary *userInfo;
                                        if (executionResponse.errorDescriptor.message) {
                                            userInfo = @{NSLocalizedDescriptionKey : executionResponse.errorDescriptor.message};
                                        }
                                        NSError *error = [NSError errorWithDomain:JSErrorDomain
                                                                             code:JSReportLoaderErrorTypeLoadingCanceled
                                                                         userInfo:userInfo];
                                        [strongSelf handleError:error withLoadedObjects:nil forPage:NSNotFound];
                                    } else {
                                        strongSelf.reportExecutionStatus = executionResponse.status;
                                        if (executionResponse.status.status == kJS_EXECUTION_STATUS_READY) {
                                            NSInteger countOfPages = executionResponse.totalPages.integerValue;
                                            [strongSelf.report updateCountOfPages:countOfPages];
                                        } else {
                                            [strongSelf checkingExecutionStatus];
                                        }
                                        if (strongSelf.report.countOfPages > 0) {
                                            [strongSelf startExportExecutionForPage:self.report.currentPage];
                                        } else {
                                            [strongSelf handleEmptyReport];
                                        }
                                    }
                                } else {
                                    NSError *error = [JSErrorBuilder errorWithCode:JSClientErrorCode];
                                    [strongSelf handleError:error withLoadedObjects:nil forPage:NSNotFound];
                                }
                            }
                        }];
}

- (void) startExportExecutionForPage:(NSInteger)page {
    NSDictionary *cachedPages = [self cachedReportPages];
    NSString *HTMLString = cachedPages[@(page)];
    if (HTMLString && self.loadPageCompletionBlock) { // show cached page
#ifndef __RELEASE__
        NSLog(@"load cached page");
#endif
        [self.report updateHTMLString:HTMLString baseURLSring:self.report.baseURLString];
        self.report.isReportAlreadyLoaded = (HTMLString.length > 0);
        
        [self startLoadReportHTML];
    } else { // export page
        NSString *exportID = self.exportIdsDictionary[@(page)];
        if (exportID) {
            if (exportID.length) {
                [self loadOutputResourcesForPage:page];
            }
        } else if (page <= self.report.countOfPages) {
            __weak typeof(self) weakSelf = self;
            [self.restClient runExportExecution:self.report.requestId
                                   outputFormat:kJS_CONTENT_TYPE_HTML
                                          pages:@(page).stringValue
                                     markupType:(self.needEmbeddableOutput ? JSMarkupTypeEmbeddable : JSMarkupTypeFull)
                              attachmentsPrefix:self.configuration.attachmentsPrefix
                                completionBlock:^(JSOperationResult *result) {
                                    __strong typeof(self) strongSelf = weakSelf;
                                    if (result.error) {
                                        [strongSelf handleError:result.error withLoadedObjects:result.objects forPage:page];
                                    } else {
                                        JSExportExecutionResponse *export = [result.objects firstObject];
                                        
                                        if (export.uuid.length) {
                                            strongSelf.exportIdsDictionary[@(page)] = export.uuid;
                                            [strongSelf loadOutputResourcesForPage:page];
                                        } else {
                                            NSError *error = [JSErrorBuilder errorWithCode:JSClientErrorCode];
                                            [strongSelf handleError:error withLoadedObjects:nil forPage:page];
                                        }
                                    }
                                }];
        }
    }
}

- (void)loadOutputResourcesForPage:(NSInteger)page {
    if (page == self.report.currentPage) {
        self.outputResourceType = JSReportLoaderOutputResourceType_LoadingNow;
    }
    NSString *exportID = self.exportIdsDictionary[@(page)];
    
    // Fix for JRS version smaller 5.6.0
    NSString *fullExportID = exportID;
    if (self.restClient.serverInfo.versionAsFloat < kJS_SERVER_VERSION_CODE_EMERALD_5_6_0) {
        fullExportID = [NSString stringWithFormat:@"%@;pages=%@", exportID, @(page)];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.restClient loadReportOutput:self.report.requestId
                         exportOutput:fullExportID
                        loadForSaving:NO
                                 path:nil
                      completionBlock:^(JSOperationResult *result) {
                          __strong typeof(self) strongSelf = weakSelf;
                          if (result.error && result.error.code != JSOtherErrorCode) {
                              [strongSelf handleError:result.error withLoadedObjects:result.objects forPage:page];
                          } else {
                              if ([result.MIMEType isEqualToString:[JSUtils usedMimeType]]) {
                                  [strongSelf handleError:result.error withLoadedObjects:result.objects forPage:page];
                              } else {
                                  strongSelf.outputResourceType = [result.allHeaderFields[@"output-final"] boolValue]? JSReportLoaderOutputResourceType_Final : JSReportLoaderOutputResourceType_NotFinal;
                                  
                                  if (strongSelf.outputResourceType == JSReportLoaderOutputResourceType_Final) {
                                      [strongSelf cacheHTMLString:result.bodyAsString forPageNumber:page];
                                  }
                                  
                                  if (page == strongSelf.report.currentPage) { // show current page
                                      strongSelf.isReportInLoadingProcess = NO;
                                      if (strongSelf.loadPageCompletionBlock) {
                                          [strongSelf.report updateHTMLString:result.bodyAsString
                                                                 baseURLSring:strongSelf.restClient.serverProfile.serverUrl];
                                          strongSelf.report.isReportAlreadyLoaded = (result.bodyAsString.length > 0);
                                          [strongSelf startLoadReportHTML];
                                      }
                                  }
                                  
                                  // Try to load second page
                                  if (strongSelf.report.currentPage == 1) {
                                      if ([strongSelf.exportIdsDictionary count] == 1) {
                                          [strongSelf startExportExecutionForPage:2];
                                      }
                                      
                                      if (page == 2 && [strongSelf.exportIdsDictionary count] == 2) {
                                          [strongSelf.report updateIsMultiPageReport:YES];
                                      }
                                  }
                              }
                          }
                      }];
}

- (void)startLoadReportHTML {
    if (self.loadPageCompletionBlock) {
        self.loadPageCompletionBlock(YES, nil);
    }
}

#pragma mark - Check status

- (void)checkingExecutionStatus {
    [self performSelector:@selector(makeStatusChecking) withObject:nil afterDelay:kJSExecutionStatusCheckingInterval];
}

- (void) makeStatusChecking {
    __weak typeof(self) weakSelf = self;
    [self.restClient reportExecutionStatusForRequestId:self.report.requestId
                                       completionBlock:^(JSOperationResult *result) {
                                           __strong typeof(self) strongSelf = weakSelf;
                                           if (result.error) {
                                               [strongSelf handleError:result.error withLoadedObjects:result.objects forPage:NSNotFound];
                                           } else {
                                               strongSelf.reportExecutionStatus = [result.objects firstObject];
                                               if (strongSelf.reportExecutionStatus.status == kJS_EXECUTION_STATUS_READY) {
                                                   [strongSelf stopStatusChecking];
                                               } else if (strongSelf.reportExecutionStatus.status == kJS_EXECUTION_STATUS_QUEUED ||
                                                          strongSelf.reportExecutionStatus.status == kJS_EXECUTION_STATUS_EXECUTION) {
                                                   [strongSelf checkingExecutionStatus];
                                               } else {
                                                   NSError *error = [JSErrorBuilder errorWithCode:JSClientErrorCode ];
                                                   [strongSelf handleError:error withLoadedObjects:nil forPage:NSNotFound];
                                               }
                                           }
                                       }];
}

- (void)stopStatusChecking {
    BOOL isNotFinal = self.outputResourceType == JSReportLoaderOutputResourceType_NotFinal;
    BOOL isLoadingNow = self.outputResourceType == JSReportLoaderOutputResourceType_LoadingNow;
    if (isNotFinal && !isLoadingNow) {
        [self startExportExecutionForPage:self.report.currentPage];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.restClient reportExecutionMetadataForRequestId:self.report.requestId
                                         completionBlock:^(JSOperationResult *result) {
                                             __strong typeof(self) strongSelf = weakSelf;
                                             if (result.error) {
                                                 [strongSelf handleError:result.error withLoadedObjects:result.objects forPage:NSNotFound];

                                             } else {
                                                 JSReportExecutionResponse *response = [result.objects firstObject];
                                                 NSInteger countOfPages = response.totalPages.integerValue;
                                                 if (countOfPages > 0) {
                                                     [strongSelf.report updateCountOfPages:countOfPages];
                                                 } else {
                                                     [strongSelf handleEmptyReport];
                                                 }
                                             }
                                         }];
}

#pragma mark - Handlers
- (void)handleEmptyReport {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey : JSCustomLocalizedString(@"report.viewer.emptyreport.title", nil)};
    NSError *error = [NSError errorWithDomain:JSErrorDomain
                                         code:JSReportLoaderErrorTypeEmtpyReport
                                     userInfo:userInfo];
    [self handleError:error withLoadedObjects:nil forPage:NSNotFound];
}

- (void)handleError:(NSError *)error withLoadedObjects:(NSArray *)objects forPage:(NSInteger)page {
    if (page != self.report.currentPage && page != NSNotFound && objects.count){
        JSErrorDescriptor *error = [objects firstObject];
        if ([error isKindOfClass:[JSErrorDescriptor class]]) {
            BOOL isIllegalParameter = [error.errorCode isEqualToString:@"illegal.parameter.value.error"];
            BOOL isPagesOutOfRange = [error.errorCode isEqualToString:@"export.pages.out.of.range"];
            BOOL isExportFailed = [error.errorCode isEqualToString:@"export.failed"];
            if (isIllegalParameter || isPagesOutOfRange || isExportFailed) {
                [self.report updateCountOfPages:page - 1];
            }
        }
    } else {
        if (self.loadPageCompletionBlock) {
            self.loadPageCompletionBlock(NO, error);
        }
        [self cancel];
    }
}

#pragma mark - Cache pages
- (void)cacheHTMLString:(NSString *)HTMLString forPageNumber:(NSInteger)pageNumber {
    self.cachedPages[@(pageNumber)] = HTMLString;
}

- (NSDictionary *)cachedReportPages {
    return [self.cachedPages copy];
}

- (void)clearCachedReportPages {
    self.cachedPages = [@{} mutableCopy];
}

@end
