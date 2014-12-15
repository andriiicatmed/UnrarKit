//
//  URKArchive.mm
//  UnrarKit
//
//

#import "URKArchive.h"
#import "URKFileInfo.h"
#import "NSString+UnrarKit.h"

#import "rar.hpp"


NSString *URKErrorDomain = @"URKErrorDomain";

@interface URKArchive ()

@property (strong) NSData *fileBookmark;

@end


@implementation URKArchive

int CALLBACK CallbackProc(UINT msg, long UserData, long P1, long P2) {
	UInt8 **buffer;
	
	switch(msg) {
			
		case UCM_CHANGEVOLUME:
			break;
		case UCM_PROCESSDATA:
			buffer = (UInt8 **) UserData;
			memcpy(*buffer, (UInt8 *)P1, P2);
			// advance the buffer ptr, original m_buffer ptr is untouched
			*buffer += P2;
			break;
		case UCM_NEEDPASSWORD:
			break;
	}
	return(0);
}



#pragma mark - Convenience Methods


+ (URKArchive *)rarArchiveAtPath:(NSString *)filePath
{
    return [[URKArchive alloc] initWithFile:[NSURL fileURLWithPath:filePath]];
}

+ (URKArchive *)rarArchiveAtURL:(NSURL *)fileURL
{
    return [[URKArchive alloc] initWithFile:fileURL];
}

+ (URKArchive *)rarArchiveAtPath:(NSString *)filePath password:(NSString *)password
{
    return [[URKArchive alloc] initWithFile:[NSURL fileURLWithPath:filePath]
                                   password:password];
}

+ (URKArchive *)rarArchiveAtURL:(NSURL *)fileURL password:(NSString *)password
{
    return [[URKArchive alloc] initWithFile:fileURL password:password];
}



#pragma mark - Initializers


- (id)initWithFile:(NSURL *)fileURL
{
    if ((self = [super init])) {
        NSError *error = nil;
        self.fileBookmark = [fileURL bookmarkDataWithOptions:0
                              includingResourceValuesForKeys:@[]
                                               relativeToURL:nil
                                                       error:&error];
        
        if (error) {
            NSLog(@"Error creating bookmark to RAR archive: %@", error);
        }
    }
    
	return self;
}

- (id)initWithFile:(NSURL *)fileURL password:(NSString*)password
{
	if ((self = [self initWithFile:fileURL])) {
        self.password = password;
    }
    
    return self;
}


#pragma mark - Properties


- (NSURL *)fileURL
{
    BOOL bookmarkIsStale = NO;
    NSError *error = nil;
    
    NSURL *result = [NSURL URLByResolvingBookmarkData:self.fileBookmark
                                              options:0
                                        relativeToURL:nil
                                  bookmarkDataIsStale:&bookmarkIsStale
                                                error:&error];
    
    if (error) {
        NSLog(@"Error resolving bookmark to RAR archive: %@", error);
        return nil;
    }
    
    if (bookmarkIsStale) {
        self.fileBookmark = [result bookmarkDataWithOptions:0
                             includingResourceValuesForKeys:@[]
                                              relativeToURL:nil
                                                      error:&error];
        
        if (error) {
            NSLog(@"Error creating fresh bookmark to RAR archive: %@", error);
        }
  }
    
    return result;
}

- (NSString *)filename
{
    NSURL *url = self.fileURL;
    
    if (!url) {
        return nil;
    }
    
    return url.path;
}



#pragma mark - Public Methods


- (NSArray *)listFilenames:(NSError **)error
{
    NSArray *files = [self listFileInfo:error];
    return [files valueForKey:@"filename"];
}

- (NSArray *)listFileInfo:(NSError **)error
{
    __block NSMutableArray *fileInfos = [NSMutableArray array];
    
    BOOL success = [self performActionWithArchiveOpen:^(NSError **innerError) {
        int RHCode = 0, PFCode = 0;

        while ((RHCode = RARReadHeaderEx(_rarFile, header)) == 0) {
            [fileInfos addObject:[URKFileInfo fileInfo:header]];
            
            if ((PFCode = RARProcessFile(_rarFile, RAR_SKIP, NULL, NULL)) != 0) {
                [self assignError:error code:(NSInteger)PFCode];
                fileInfos = nil;
                return;
            }
        }
        
        if (RHCode != ERAR_SUCCESS && RHCode != ERAR_END_ARCHIVE) {
            [self assignError:error code:RHCode];
            fileInfos = nil;
        }
    } inMode:RAR_OM_LIST_INCSPLIT error:error];

	if (!success || !fileInfos) {
        return nil;
    }

    return [NSArray arrayWithArray:fileInfos];
}

- (BOOL)extractFilesTo:(NSString *)filePath overWrite:(BOOL)overwrite error:(NSError **)error
{
    __block BOOL result = YES;
    
    BOOL success = [self performActionWithArchiveOpen:^(NSError **innerError) {
        int RHCode = 0, PFCode = 0;

        while ((RHCode = RARReadHeaderEx(_rarFile, header)) == ERAR_SUCCESS) {
            if ([self headerContainsErrors:error]) {
                result = NO;
                return;
            }
            
            if ((PFCode = RARProcessFileW(_rarFile, RAR_EXTRACT, unicharsFromString(filePath), NULL)) != 0) {
                [self assignError:error code:(NSInteger)PFCode];
                result = NO;
                return;
            }
        }
        
        if (RHCode != ERAR_SUCCESS && RHCode != ERAR_END_ARCHIVE) {
            [self assignError:error code:RHCode];
            result = NO;
        }
        
    } inMode:RAR_OM_EXTRACT error:error];
    
    return success && result;
}

- (NSData *)extractDataFromFile:(NSString *)filePath error:(NSError **)error
{
    __block NSData *result = nil;
    
    BOOL success = [self performActionWithArchiveOpen:^(NSError **innerError) {
        int RHCode = 0, PFCode = 0;
        
        size_t length = 0;
        while ((RHCode = RARReadHeaderEx(_rarFile, header)) == ERAR_SUCCESS) {
            if ([self headerContainsErrors:error]) {
                return;
            }
            
            NSString *filename = [NSString stringWithUnichars:header->FileNameW];

            if ([filename isEqualToString:filePath]) {
                length = header->UnpSize;
                break;
            }
            else {
                if ((PFCode = RARProcessFileW(_rarFile, RAR_SKIP, NULL, NULL)) != 0) {
                    [self assignError:error code:(NSInteger)PFCode];
                    return;
                }
            }
        }
        
        if (RHCode != ERAR_SUCCESS) {
            [self assignError:error code:RHCode];
            return;
        }
        
        // Empty file, or a directory
        if (length == 0) {
            result = [NSData data];
            return;
        }
        
        UInt8 *buffer = (UInt8 *)malloc(length * sizeof(UInt8));
        UInt8 *callBackBuffer = buffer;
        
        RARSetCallback(_rarFile, CallbackProc, (long) &callBackBuffer);
        
        PFCode = RARProcessFile(_rarFile, RAR_TEST, NULL, NULL);
        
        if (PFCode != 0) {
            [self assignError:error code:(NSInteger)PFCode];
            return;
        }
        
        result = [NSData dataWithBytesNoCopy:buffer length:length freeWhenDone:YES];
    } inMode:RAR_OM_EXTRACT error:error];
    
    if (!success) {
        return nil;
    }
    
    return result;
}

- (BOOL)performOnDataInArchive:(void (^)(NSString *, NSData *, BOOL *))action
                         error:(NSError **)error
{
    BOOL success = [self performActionWithArchiveOpen:^(NSError **innerError) {
        int RHCode = 0, PFCode = 0;
        
        BOOL stop = NO;
        
        size_t length = 0;
        while ((RHCode = RARReadHeaderEx(_rarFile, header)) == 0) {
            if (stop || [self headerContainsErrors:error]) {
                return;
            }
            
            NSString *filename = [NSString stringWithCString:header->FileName encoding:NSASCIIStringEncoding];
            length = header->UnpSize;

            // Empty file, or a directory
            if (length == 0) {
                action(filename, [NSData data], &stop);
                break;
            }
            
            UInt8 *buffer = (UInt8 *)malloc(length * sizeof(UInt8));
            UInt8 *callBackBuffer = buffer;
            
            RARSetCallback(_rarFile, CallbackProc, (long) &callBackBuffer);
            
            PFCode = RARProcessFile(_rarFile, RAR_TEST, NULL, NULL);
            
            if (PFCode != 0) {
                [self assignError:error code:(NSInteger)PFCode];
                return;
            }
            
            NSData *data = [NSData dataWithBytesNoCopy:buffer length:length freeWhenDone:YES];
            action(filename, data, &stop);
        }
        
        if (RHCode != ERAR_SUCCESS) {
            [self assignError:error code:RHCode];
            return;
        }
    } inMode:RAR_OM_EXTRACT error:error];
    
    return success;
}

- (BOOL)isPasswordProtected
{
    @try {
        NSError *error = nil;
        if (![self _unrarOpenFile:self.filename
                           inMode:RAR_OM_EXTRACT
                     withPassword:nil
                            error:&error])
        {
            return NO;
        }
        
        if (error) {
            NSLog(@"Error checking for password: %@", error);
            return NO;
        }
        
        int RHCode = RARReadHeaderEx(_rarFile, header);
        int PFCode = RARProcessFile(_rarFile, RAR_TEST, NULL, NULL);
        
        if ([self headerContainsErrors:&error]) {
            NSLog(@"Errors in header while checking for password: %@", error);
            return error.code == ERAR_MISSING_PASSWORD;
        }
        
        if (RHCode == ERAR_MISSING_PASSWORD || PFCode == ERAR_MISSING_PASSWORD)
            return YES;
    }
    @finally {
        [self closeFile];
    }
    
    return NO;
}

- (BOOL)validatePassword
{
    __block NSError *error = nil;
    __block BOOL result = NO;
    
    BOOL success = [self performActionWithArchiveOpen:^(NSError **innerError) {
        if (error) {
            NSLog(@"Error validating password: %@", error);
            return;
        }
        
        int RHCode = RARReadHeaderEx(_rarFile, header);
        int PFCode = RARProcessFile(_rarFile, RAR_TEST, NULL, NULL);
        
        if ([self headerContainsErrors:&error] && error.code == ERAR_MISSING_PASSWORD) {
            NSLog(@"Errors in header while validating password: %@", error);
            return;
        }
        
        if (RHCode == ERAR_MISSING_PASSWORD || PFCode == ERAR_MISSING_PASSWORD || RHCode == ERAR_BAD_DATA || PFCode == ERAR_BAD_DATA)
            return;
        
        result = YES;
    } inMode:RAR_OM_EXTRACT error:&error];
    
    return success && result;
}



#pragma mark - Private Methods


- (BOOL)performActionWithArchiveOpen:(void(^)(NSError **innerError))action
                              inMode:(NSInteger)mode
                               error:(NSError **)error
{
    if (error) {
        *error = nil;
    }
    
    if (![self _unrarOpenFile:self.filename
                       inMode:mode
                 withPassword:self.password
                        error:error]) {
        return NO;
    }
    
    @try {
        action(error);
    }
    @finally {
        [self closeFile];
    }
    
    return !error || !*error;
}

- (BOOL)_unrarOpenFile:(NSString *)rarFile inMode:(NSInteger)mode withPassword:(NSString *)aPassword error:(NSError **)error
{
    if (error) {
        *error = nil;
    }
    
    ErrHandler.Clean();
    
    header = new RARHeaderDataEx;
    bzero(header, sizeof(RARHeaderDataEx));
	flags = new RAROpenArchiveDataEx;
    bzero(flags, sizeof(RAROpenArchiveDataEx));
	
	const char *filenameData = (const char *) [rarFile UTF8String];
	flags->ArcName = new char[strlen(filenameData) + 1];
	strcpy(flags->ArcName, filenameData);
	flags->OpenMode = mode;
	
	_rarFile = RAROpenArchiveEx(flags);
	if (_rarFile == 0 || flags->OpenResult != 0) {
        [self assignError:error code:(NSInteger)flags->OpenResult];
		return NO;
    }
	
    if(aPassword != nil) {
        char *password = (char *) [aPassword UTF8String];
        RARSetPassword(_rarFile, password);
    }
    
	return YES;
}

- (BOOL)closeFile;
{
    if (_rarFile)
        RARCloseArchive(_rarFile);
    _rarFile = 0;
    
    if (flags)
        delete flags->ArcName;
    delete flags, flags = 0;
    delete header, header = 0;
    return YES;
}

- (NSString *)errorNameForErrorCode:(NSInteger)errorCode
{
    NSString *errorName;
    
    switch (errorCode) {
        case ERAR_END_ARCHIVE:
            errorName = @"ERAR_END_ARCHIVE";
            break;
            
        case ERAR_NO_MEMORY:
            errorName = @"ERAR_NO_MEMORY";
            break;
            
        case ERAR_BAD_DATA:
            errorName = @"ERAR_BAD_DATA";
            break;
            
        case ERAR_BAD_ARCHIVE:
            errorName = @"ERAR_BAD_ARCHIVE";
            break;
            
        case ERAR_UNKNOWN_FORMAT:
            errorName = @"ERAR_UNKNOWN_FORMAT";
            break;
            
        case ERAR_EOPEN:
            errorName = @"ERAR_EOPEN";
            break;
            
        case ERAR_ECREATE:
            errorName = @"ERAR_ECREATE";
            break;
            
        case ERAR_ECLOSE:
            errorName = @"ERAR_ECLOSE";
            break;
            
        case ERAR_EREAD:
            errorName = @"ERAR_EREAD";
            break;
            
        case ERAR_EWRITE:
            errorName = @"ERAR_EWRITE";
            break;
            
        case ERAR_SMALL_BUF:
            errorName = @"ERAR_SMALL_BUF";
            break;
            
        case ERAR_UNKNOWN:
            errorName = @"ERAR_UNKNOWN";
            break;
            
        case ERAR_MISSING_PASSWORD:
            errorName = @"ERAR_MISSING_PASSWORD";
            break;
            
        case ERAR_ARCHIVE_NOT_FOUND:
            errorName = @"ERAR_ARCHIVE_NOT_FOUND";
            break;
            
        default:
            errorName = [NSString stringWithFormat:@"Unknown error code: %u", flags->OpenResult];
            break;
    }
    
    return errorName;
}

- (BOOL)assignError:(NSError **)error code:(NSInteger)errorCode
{
    if (error) {
        NSString *errorName = [self errorNameForErrorCode:errorCode];
        
        *error = [NSError errorWithDomain:URKErrorDomain
                                     code:errorCode
                                 userInfo:@{NSLocalizedFailureReasonErrorKey: errorName}];
    }
    
    return NO;
}

- (BOOL)headerContainsErrors:(NSError **)error
{
    BOOL isPasswordProtected = header->Flags & 0x04;
    
    if (isPasswordProtected && !self.password) {
        [self assignError:error code:ERAR_MISSING_PASSWORD];
        return YES;
    }
    
    return NO;
}

static wchar_t *unicharsFromString(NSString *string) {
    return (wchar_t *)[string cStringUsingEncoding:NSUTF32LittleEndianStringEncoding];}

@end
