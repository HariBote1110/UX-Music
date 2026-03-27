#ifndef KALAM_H
#define KALAM_H

#ifdef __cplusplus
extern "C" {
#endif

// Callback type definition
// The char* is a JSON string allocated by the library (or static).
// Caller should likely NOT free it unless specified? 
// Usually callbacks in C# Native AOT passed to C might hand over ownership or be transient.
// Given koffi usage in JS, it just parses the string.
typedef void (*on_cb_result_t)(char*);

void Initialize(on_cb_result_t onDonePtr);
void FetchDeviceInfo(on_cb_result_t onDonePtr);
void FetchStorages(on_cb_result_t onDonePtr);
void Walk(char* walkInputJson, on_cb_result_t onDonePtr);
void DownloadFiles(char* downloadFilesInputJson, on_cb_result_t onPreprocessPtr, on_cb_result_t onProgressPtr, on_cb_result_t onDonePtr);
void UploadFiles(char* uploadFilesInputJson, on_cb_result_t onPreprocessPtr, on_cb_result_t onProgressPtr, on_cb_result_t onDonePtr);
void DeleteFile(char* deleteFileInputJson, on_cb_result_t onDonePtr);
void MakeDirectory(char* makeDirectoryInputJson, on_cb_result_t onDonePtr);
void Dispose(on_cb_result_t onDonePtr);

#ifdef __cplusplus
}
#endif

#endif // KALAM_H
