//
//  CrispAudioDriver.c
//  Crisp — macOS virtual microphone (Audio Server Plug-in / HAL)
//
//  Phase 1a goal: register a virtual INPUT device named "Noise Cancelled Microphone"
//  that loops back whatever is written to its output stream onto its input stream.
//  This is the foundation the real-time engine (Phase 2) writes processed audio into.
//
//  Object model (fixed IDs):
//    kObjectID_PlugIn (== kAudioObjectPlugInObject)
//    kObjectID_Box
//    kObjectID_Device
//    kObjectID_Stream_Input    (presented to meeting/recording apps)
//    kObjectID_Stream_Output   (the app writes processed audio here)
//
//  Modeled on Apple's "NullAudio" Audio Server Plug-in reference architecture.
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

#pragma mark - Configuration

#define kPlugIn_BundleID            "ai.rtzr.crisp.audiodriver"
#define kManufacturer_Name          CFSTR("RTZR")

#define kBox_Name                   CFSTR("Crisp Audio")
#define kBox_UID                    CFSTR("CrispAudioBox:0")

#define kDevice_Name                CFSTR("Noise Cancelled Microphone")
#define kDevice_UID                 CFSTR("CrispAudioDevice:0")
#define kDevice_ModelUID            CFSTR("CrispAudio:Model:0")

#define kDevice_SampleRate          48000.0
#define kDevice_NumChannels         2
#define kDevice_BytesPerFrame       (kDevice_NumChannels * sizeof(Float32))
// Ring buffer length in frames. Must equal the device's zero-timestamp period.
#define kDevice_RingBufferSize      19200

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,  // 1
    kObjectID_Box           = 2,
    kObjectID_Device        = 3,
    kObjectID_Stream_Input  = 4,
    kObjectID_Stream_Output = 5
};

#pragma mark - State

static pthread_mutex_t   gPlugIn_StateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32            gPlugIn_RefCount = 0;
static AudioServerPlugInHostRef gPlugIn_Host = NULL;

static Boolean           gBox_Acquired = true;

// IO / timing state
static pthread_mutex_t   gDevice_IOMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt64            gDevice_IOIsRunning = 0;
static Float64           gDevice_HostTicksPerFrame = 0.0;
static UInt64            gDevice_NumberTimeStamps = 0;
static UInt64            gDevice_AnchorHostTime = 0;

// Loopback ring buffer (output stream -> input stream)
static Float32           gRingBuffer[kDevice_RingBufferSize * kDevice_NumChannels];

#pragma mark - Forward declarations

static HRESULT  Crisp_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    Crisp_AddRef(void* inDriver);
static ULONG    Crisp_Release(void* inDriver);
static OSStatus Crisp_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Crisp_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus Crisp_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Crisp_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Crisp_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Crisp_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus Crisp_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  Crisp_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus Crisp_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus Crisp_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus Crisp_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus Crisp_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus Crisp_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Crisp_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Crisp_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus Crisp_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus Crisp_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus Crisp_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus Crisp_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - Interface vtable

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface = {
    NULL,
    Crisp_QueryInterface,
    Crisp_AddRef,
    Crisp_Release,
    Crisp_Initialize,
    Crisp_CreateDevice,
    Crisp_DestroyDevice,
    Crisp_AddDeviceClient,
    Crisp_RemoveDeviceClient,
    Crisp_PerformDeviceConfigurationChange,
    Crisp_AbortDeviceConfigurationChange,
    Crisp_HasProperty,
    Crisp_IsPropertySettable,
    Crisp_GetPropertyDataSize,
    Crisp_GetPropertyData,
    Crisp_SetPropertyData,
    Crisp_StartIO,
    Crisp_StopIO,
    Crisp_GetZeroTimeStamp,
    Crisp_WillDoIOOperation,
    Crisp_BeginIOOperation,
    Crisp_DoIOOperation,
    Crisp_EndIOOperation
};
static AudioServerPlugInDriverInterface* gAudioServerPlugInDriverInterfacePtr = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef gAudioServerPlugInDriverRef = &gAudioServerPlugInDriverInterfacePtr;

#pragma mark - Factory (referenced from Info.plist CFPlugInFactories)

// Must be exported by name so CFPlugIn can resolve it (the rest of the file is -fvisibility=hidden).
#define CRISP_EXPORT __attribute__((visibility("default")))

CRISP_EXPORT void* CrispAudioDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
CRISP_EXPORT void* CrispAudioDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    #pragma unused(inAllocator)
    if(CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gAudioServerPlugInDriverRef;
    }
    return NULL;
}

#pragma mark - COM

static HRESULT Crisp_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if(inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if(outInterface == NULL) return kAudioHardwareIllegalOperationError;

    CFUUIDRef theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if(theRequestedUUID == NULL) return kAudioHardwareIllegalOperationError;

    HRESULT theAnswer;
    if(CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        ++gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        *outInterface = gAudioServerPlugInDriverRef;
        theAnswer = 0;            // S_OK
    } else {
        theAnswer = (HRESULT)0x80000004;   // E_NOINTERFACE
    }
    CFRelease(theRequestedUUID);
    return theAnswer;
}

static ULONG Crisp_AddRef(void* inDriver)
{
    if(inDriver != gAudioServerPlugInDriverRef) return 0;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount < UINT32_MAX) ++gPlugIn_RefCount;
    ULONG theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return theAnswer;
}

static ULONG Crisp_Release(void* inDriver)
{
    if(inDriver != gAudioServerPlugInDriverRef) return 0;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount > 0) --gPlugIn_RefCount;
    ULONG theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return theAnswer;
}

#pragma mark - Lifecycle

static OSStatus Crisp_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if(inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    gPlugIn_Host = inHost;

    // Host ticks per frame, used by GetZeroTimeStamp.
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    Float64 theHostClockFrequency = ((Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer) * 1000000000.0;
    gDevice_HostTicksPerFrame = theHostClockFrequency / kDevice_SampleRate;

    memset(gRingBuffer, 0, sizeof(gRingBuffer));
    return 0;
}

static OSStatus Crisp_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    #pragma unused(inDriver, inDescription, inClientInfo, outDeviceObjectID)
    return kAudioHardwareUnsupportedOperationError;   // static device, no dynamic creation
}

static OSStatus Crisp_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    #pragma unused(inDriver, inDeviceObjectID)
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Crisp_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inDriver, inDeviceObjectID, inClientInfo)
    return 0;
}

static OSStatus Crisp_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inDriver, inDeviceObjectID, inClientInfo)
    return 0;
}

static OSStatus Crisp_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inDriver, inDeviceObjectID, inChangeAction, inChangeInfo)
    return 0;   // single fixed sample rate; nothing to apply
}

static OSStatus Crisp_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inDriver, inDeviceObjectID, inChangeAction, inChangeInfo)
    return 0;
}

#pragma mark - Property helpers

static void Crisp_FillASBD(AudioStreamBasicDescription* outFormat)
{
    outFormat->mSampleRate       = kDevice_SampleRate;
    outFormat->mFormatID         = kAudioFormatLinearPCM;
    outFormat->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket   = kDevice_BytesPerFrame;
    outFormat->mFramesPerPacket  = 1;
    outFormat->mBytesPerFrame    = kDevice_BytesPerFrame;
    outFormat->mChannelsPerFrame = kDevice_NumChannels;
    outFormat->mBitsPerChannel   = 32;
    outFormat->mReserved         = 0;
}

#pragma mark - HasProperty

static Boolean Crisp_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)
    if(inDriver != gAudioServerPlugInDriverRef || inAddress == NULL) return false;

    // Probe via GetPropertyDataSize: if it returns success the property exists.
    UInt32 theSize = 0;
    return Crisp_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, 0, NULL, &theSize) == 0;
}

#pragma mark - IsPropertySettable

static OSStatus Crisp_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)
    if(inDriver != gAudioServerPlugInDriverRef || inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    // Nothing in this PoC is settable from clients.
    *outIsSettable = false;
    return 0;
}

#pragma mark - GetPropertyDataSize

static OSStatus Crisp_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    if(inDriver != gAudioServerPlugInDriverRef || inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;

    OSStatus err = 0;
    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            switch(inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:           *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:               *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:               *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyManufacturer:        *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:        *outDataSize = 2 * sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyBoxList:             *outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyTranslateUIDToBox:   *outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyDeviceList:          *outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyTranslateUIDToDevice:*outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyResourceBundle:      *outDataSize = sizeof(CFStringRef); break;
                default: err = kAudioHardwareUnknownPropertyError; break;
            }
            break;

        case kObjectID_Box:
            switch(inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:           *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:               *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:               *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName:                *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyModelName:           *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyManufacturer:        *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:        *outDataSize = 0; break;
                case kAudioObjectPropertyIdentify:            *outDataSize = sizeof(UInt32); break;
                case kAudioObjectPropertySerialNumber:        *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyFirmwareVersion:     *outDataSize = sizeof(CFStringRef); break;
                case kAudioBoxPropertyBoxUID:                 *outDataSize = sizeof(CFStringRef); break;
                case kAudioBoxPropertyTransportType:          *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyHasAudio:               *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyHasVideo:               *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyHasMIDI:                *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyIsProtected:            *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyAcquired:               *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyAcquisitionFailed:      *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyDeviceList:             *outDataSize = sizeof(AudioObjectID); break;
                default: err = kAudioHardwareUnknownPropertyError; break;
            }
            break;

        case kObjectID_Device:
            switch(inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:                   *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:                       *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:                       *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName:                        *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyManufacturer:                *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects: {
                    switch(inAddress->mScope) {
                        case kAudioObjectPropertyScopeInput:  *outDataSize = 1 * sizeof(AudioObjectID); break;
                        case kAudioObjectPropertyScopeOutput: *outDataSize = 1 * sizeof(AudioObjectID); break;
                        default:                              *outDataSize = 2 * sizeof(AudioObjectID); break;
                    }
                    break;
                }
                case kAudioDevicePropertyDeviceUID:                   *outDataSize = sizeof(CFStringRef); break;
                case kAudioDevicePropertyModelUID:                    *outDataSize = sizeof(CFStringRef); break;
                case kAudioDevicePropertyTransportType:               *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyRelatedDevices:              *outDataSize = sizeof(AudioObjectID); break;
                case kAudioDevicePropertyClockDomain:                 *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsAlive:               *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsRunning:             *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyLatency:                     *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyStreams: {
                    switch(inAddress->mScope) {
                        case kAudioObjectPropertyScopeInput:  *outDataSize = 1 * sizeof(AudioObjectID); break;
                        case kAudioObjectPropertyScopeOutput: *outDataSize = 1 * sizeof(AudioObjectID); break;
                        default:                              *outDataSize = 2 * sizeof(AudioObjectID); break;
                    }
                    break;
                }
                case kAudioObjectPropertyControlList:                 *outDataSize = 0; break;
                case kAudioDevicePropertySafetyOffset:                *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyNominalSampleRate:           *outDataSize = sizeof(Float64); break;
                case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); break;
                case kAudioDevicePropertyIsHidden:                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyPreferredChannelsForStereo:  *outDataSize = 2 * sizeof(UInt32); break;
                case kAudioDevicePropertyPreferredChannelLayout:      *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kDevice_NumChannels * sizeof(AudioChannelDescription)); break;
                case kAudioDevicePropertyZeroTimeStampPeriod:         *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyIcon:                        *outDataSize = sizeof(CFURLRef); break;
                default: err = kAudioHardwareUnknownPropertyError; break;
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch(inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:               *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:                   *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:                   *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyOwnedObjects:            *outDataSize = 0; break;
                case kAudioStreamPropertyIsActive:                *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyDirection:               *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyTerminalType:            *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyStartingChannel:         *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyLatency:                 *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyVirtualFormat:           *outDataSize = sizeof(AudioStreamBasicDescription); break;
                case kAudioStreamPropertyPhysicalFormat:          *outDataSize = sizeof(AudioStreamBasicDescription); break;
                case kAudioStreamPropertyAvailableVirtualFormats: *outDataSize = sizeof(AudioStreamRangedDescription); break;
                case kAudioStreamPropertyAvailablePhysicalFormats:*outDataSize = sizeof(AudioStreamRangedDescription); break;
                default: err = kAudioHardwareUnknownPropertyError; break;
            }
            break;

        default:
            err = kAudioHardwareBadObjectError;
            break;
    }
    return err;
}

#pragma mark - GetPropertyData

static OSStatus Crisp_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID)
    if(inDriver != gAudioServerPlugInDriverRef || inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;

    OSStatus err = 0;
    UInt32 written = 0;

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            switch(inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *(AudioClassID*)outData = kAudioObjectClassID; written = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:
                    *(AudioClassID*)outData = kAudioPlugInClassID; written = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:
                    *(AudioObjectID*)outData = kAudioObjectUnknown; written = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyManufacturer:
                    *(CFStringRef*)outData = (CFStringRef)CFRetain(kManufacturer_Name); written = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID* list = (AudioObjectID*)outData;
                    UInt32 cap = inDataSize / sizeof(AudioObjectID);
                    UInt32 n = 0;
                    if(n < cap) list[n++] = kObjectID_Box;
                    if(n < cap) list[n++] = kObjectID_Device;
                    written = n * sizeof(AudioObjectID);
                    break;
                }
                case kAudioPlugInPropertyBoxList:
                    *(AudioObjectID*)outData = kObjectID_Box; written = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyTranslateUIDToBox: {
                    if(inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) { err = kAudioHardwareIllegalOperationError; break; }
                    CFStringRef uid = *(const CFStringRef*)inQualifierData;
                    *(AudioObjectID*)outData = (uid != NULL && CFEqual(uid, kBox_UID)) ? kObjectID_Box : kAudioObjectUnknown;
                    written = sizeof(AudioObjectID);
                    break;
                }
                case kAudioPlugInPropertyDeviceList:
                    *(AudioObjectID*)outData = kObjectID_Device; written = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    if(inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) { err = kAudioHardwareIllegalOperationError; break; }
                    CFStringRef uid = *(const CFStringRef*)inQualifierData;
                    *(AudioObjectID*)outData = (uid != NULL && CFEqual(uid, kDevice_UID)) ? kObjectID_Device : kAudioObjectUnknown;
                    written = sizeof(AudioObjectID);
                    break;
                }
                case kAudioPlugInPropertyResourceBundle:
                    *(CFStringRef*)outData = CFSTR(""); written = sizeof(CFStringRef); break;
                default: err = kAudioHardwareUnknownPropertyError; break;
            }
            break;

        case kObjectID_Box:
            switch(inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *(AudioClassID*)outData = kAudioObjectClassID; written = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:
                    *(AudioClassID*)outData = kAudioBoxClassID; written = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:
                    *(AudioObjectID*)outData = kObjectID_PlugIn; written = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName:
                    *(CFStringRef*)outData = (CFStringRef)CFRetain(kBox_Name); written = sizeof(CFStringRef); break;
                case kAudioObjectPropertyModelName:
                    *(CFStringRef*)outData = (CFStringRef)CFRetain(kBox_Name); written = sizeof(CFStringRef); break;
                case kAudioObjectPropertyManufacturer:
                    *(CFStringRef*)outData = (CFStringRef)CFRetain(kManufacturer_Name); written = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:
                    written = 0; break;
                case kAudioObjectPropertyIdentify:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioObjectPropertySerialNumber:
                    *(CFStringRef*)outData = CFSTR("0"); written = sizeof(CFStringRef); break;
                case kAudioObjectPropertyFirmwareVersion:
                    *(CFStringRef*)outData = CFSTR("1.0"); written = sizeof(CFStringRef); break;
                case kAudioBoxPropertyBoxUID:
                    *(CFStringRef*)outData = (CFStringRef)CFRetain(kBox_UID); written = sizeof(CFStringRef); break;
                case kAudioBoxPropertyTransportType:
                    *(UInt32*)outData = kAudioDeviceTransportTypeVirtual; written = sizeof(UInt32); break;
                case kAudioBoxPropertyHasAudio:
                    *(UInt32*)outData = 1; written = sizeof(UInt32); break;
                case kAudioBoxPropertyHasVideo:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioBoxPropertyHasMIDI:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioBoxPropertyIsProtected:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioBoxPropertyAcquired:
                    *(UInt32*)outData = gBox_Acquired ? 1 : 0; written = sizeof(UInt32); break;
                case kAudioBoxPropertyAcquisitionFailed:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioBoxPropertyDeviceList:
                    *(AudioObjectID*)outData = gBox_Acquired ? kObjectID_Device : kAudioObjectUnknown;
                    written = sizeof(AudioObjectID); break;
                default: err = kAudioHardwareUnknownPropertyError; break;
            }
            break;

        case kObjectID_Device:
            switch(inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *(AudioClassID*)outData = kAudioObjectClassID; written = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:
                    *(AudioClassID*)outData = kAudioDeviceClassID; written = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:
                    *(AudioObjectID*)outData = kObjectID_PlugIn; written = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName:
                    *(CFStringRef*)outData = (CFStringRef)CFRetain(kDevice_Name); written = sizeof(CFStringRef); break;
                case kAudioObjectPropertyManufacturer:
                    *(CFStringRef*)outData = (CFStringRef)CFRetain(kManufacturer_Name); written = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID* list = (AudioObjectID*)outData;
                    UInt32 cap = inDataSize / sizeof(AudioObjectID);
                    UInt32 n = 0;
                    switch(inAddress->mScope) {
                        case kAudioObjectPropertyScopeInput:
                            if(n < cap) list[n++] = kObjectID_Stream_Input; break;
                        case kAudioObjectPropertyScopeOutput:
                            if(n < cap) list[n++] = kObjectID_Stream_Output; break;
                        default:
                            if(n < cap) list[n++] = kObjectID_Stream_Input;
                            if(n < cap) list[n++] = kObjectID_Stream_Output; break;
                    }
                    written = n * sizeof(AudioObjectID);
                    break;
                }
                case kAudioDevicePropertyDeviceUID:
                    *(CFStringRef*)outData = (CFStringRef)CFRetain(kDevice_UID); written = sizeof(CFStringRef); break;
                case kAudioDevicePropertyModelUID:
                    *(CFStringRef*)outData = (CFStringRef)CFRetain(kDevice_ModelUID); written = sizeof(CFStringRef); break;
                case kAudioDevicePropertyTransportType:
                    *(UInt32*)outData = kAudioDeviceTransportTypeVirtual; written = sizeof(UInt32); break;
                case kAudioDevicePropertyRelatedDevices:
                    *(AudioObjectID*)outData = kObjectID_Device; written = sizeof(AudioObjectID); break;
                case kAudioDevicePropertyClockDomain:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsAlive:
                    *(UInt32*)outData = 1; written = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsRunning:
                    pthread_mutex_lock(&gDevice_IOMutex);
                    *(UInt32*)outData = (gDevice_IOIsRunning > 0) ? 1 : 0;
                    pthread_mutex_unlock(&gDevice_IOMutex);
                    written = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    *(UInt32*)outData = 1; written = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    *(UInt32*)outData = 1; written = sizeof(UInt32); break;
                case kAudioDevicePropertyLatency:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioDevicePropertyStreams: {
                    AudioObjectID* list = (AudioObjectID*)outData;
                    UInt32 cap = inDataSize / sizeof(AudioObjectID);
                    UInt32 n = 0;
                    switch(inAddress->mScope) {
                        case kAudioObjectPropertyScopeInput:
                            if(n < cap) list[n++] = kObjectID_Stream_Input; break;
                        case kAudioObjectPropertyScopeOutput:
                            if(n < cap) list[n++] = kObjectID_Stream_Output; break;
                        default:
                            if(n < cap) list[n++] = kObjectID_Stream_Input;
                            if(n < cap) list[n++] = kObjectID_Stream_Output; break;
                    }
                    written = n * sizeof(AudioObjectID);
                    break;
                }
                case kAudioObjectPropertyControlList:
                    written = 0; break;
                case kAudioDevicePropertySafetyOffset:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioDevicePropertyNominalSampleRate:
                    *(Float64*)outData = kDevice_SampleRate; written = sizeof(Float64); break;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange* r = (AudioValueRange*)outData;
                    if(inDataSize >= sizeof(AudioValueRange)) {
                        r[0].mMinimum = kDevice_SampleRate;
                        r[0].mMaximum = kDevice_SampleRate;
                        written = sizeof(AudioValueRange);
                    }
                    break;
                }
                case kAudioDevicePropertyIsHidden:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    UInt32* ch = (UInt32*)outData;
                    if(inDataSize >= 2 * sizeof(UInt32)) { ch[0] = 1; ch[1] = 2; written = 2 * sizeof(UInt32); }
                    break;
                }
                case kAudioDevicePropertyPreferredChannelLayout: {
                    UInt32 need = offsetof(AudioChannelLayout, mChannelDescriptions) + (kDevice_NumChannels * sizeof(AudioChannelDescription));
                    if(inDataSize >= need) {
                        AudioChannelLayout* layout = (AudioChannelLayout*)outData;
                        memset(layout, 0, need);
                        layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                        layout->mNumberChannelDescriptions = kDevice_NumChannels;
                        layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                        layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                        written = need;
                    }
                    break;
                }
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    *(UInt32*)outData = kDevice_RingBufferSize; written = sizeof(UInt32); break;
                default: err = kAudioHardwareUnknownPropertyError; break;
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: {
            Boolean isInput = (inObjectID == kObjectID_Stream_Input);
            switch(inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *(AudioClassID*)outData = kAudioObjectClassID; written = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:
                    *(AudioClassID*)outData = kAudioStreamClassID; written = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:
                    *(AudioObjectID*)outData = kObjectID_Device; written = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyOwnedObjects:
                    written = 0; break;
                case kAudioStreamPropertyIsActive:
                    *(UInt32*)outData = 1; written = sizeof(UInt32); break;
                case kAudioStreamPropertyDirection:
                    *(UInt32*)outData = isInput ? 1 : 0; written = sizeof(UInt32); break;
                case kAudioStreamPropertyTerminalType:
                    *(UInt32*)outData = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    written = sizeof(UInt32); break;
                case kAudioStreamPropertyStartingChannel:
                    *(UInt32*)outData = 1; written = sizeof(UInt32); break;
                case kAudioStreamPropertyLatency:
                    *(UInt32*)outData = 0; written = sizeof(UInt32); break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    Crisp_FillASBD((AudioStreamBasicDescription*)outData);
                    written = sizeof(AudioStreamBasicDescription); break;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    if(inDataSize >= sizeof(AudioStreamRangedDescription)) {
                        AudioStreamRangedDescription* r = (AudioStreamRangedDescription*)outData;
                        Crisp_FillASBD(&r[0].mFormat);
                        r[0].mSampleRateRange.mMinimum = kDevice_SampleRate;
                        r[0].mSampleRateRange.mMaximum = kDevice_SampleRate;
                        written = sizeof(AudioStreamRangedDescription);
                    }
                    break;
                }
                default: err = kAudioHardwareUnknownPropertyError; break;
            }
            break;
        }

        default:
            err = kAudioHardwareBadObjectError;
            break;
    }

    *outDataSize = written;
    return err;
}

#pragma mark - SetPropertyData

static OSStatus Crisp_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    #pragma unused(inObjectID, inClientProcessID, inQualifierDataSize, inQualifierData, inDataSize, inData)
    if(inDriver != gAudioServerPlugInDriverRef || inAddress == NULL) return kAudioHardwareIllegalOperationError;
    // Nothing settable in this PoC.
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark - IO

static OSStatus Crisp_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gDevice_IOMutex);
    if(gDevice_IOIsRunning == 0) {
        gDevice_NumberTimeStamps = 0;
        gDevice_AnchorHostTime = mach_absolute_time();
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
    }
    ++gDevice_IOIsRunning;
    pthread_mutex_unlock(&gDevice_IOMutex);
    return 0;
}

static OSStatus Crisp_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gDevice_IOMutex);
    if(gDevice_IOIsRunning > 0) --gDevice_IOIsRunning;
    pthread_mutex_unlock(&gDevice_IOMutex);
    return 0;
}

static OSStatus Crisp_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gDevice_IOMutex);
    UInt64 theCurrentHostTime = mach_absolute_time();
    Float64 theHostTicksPerRingBuffer = gDevice_HostTicksPerFrame * ((Float64)kDevice_RingBufferSize);
    Float64 theHostTickOffset = ((Float64)(gDevice_NumberTimeStamps + 1)) * theHostTicksPerRingBuffer;
    UInt64 theNextHostTime = gDevice_AnchorHostTime + (UInt64)theHostTickOffset;
    if(theCurrentHostTime >= theNextHostTime) {
        ++gDevice_NumberTimeStamps;
    }
    *outSampleTime = (Float64)(gDevice_NumberTimeStamps * kDevice_RingBufferSize);
    *outHostTime = gDevice_AnchorHostTime + (UInt64)(((Float64)gDevice_NumberTimeStamps) * theHostTicksPerRingBuffer);
    *outSeed = 1;
    pthread_mutex_unlock(&gDevice_IOMutex);
    return 0;
}

static OSStatus Crisp_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    Boolean willDo = false;
    Boolean willDoInPlace = true;
    switch(inOperationID) {
        case kAudioServerPlugInIOOperationReadInput: willDo = true; willDoInPlace = true; break;
        case kAudioServerPlugInIOOperationWriteMix:  willDo = true; willDoInPlace = true; break;
    }
    if(outWillDo) *outWillDo = willDo;
    if(outWillDoInPlace) *outWillDoInPlace = willDoInPlace;
    return 0;
}

static OSStatus Crisp_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if(inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus Crisp_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    #pragma unused(inStreamObjectID, inClientID, ioSecondaryBuffer)
    if(inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if(ioMainBuffer == NULL || inIOCycleInfo == NULL) return 0;

    const UInt64 ringFrames = kDevice_RingBufferSize;

    if(inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // App wrote audio to the virtual device's output -> stash into ring buffer.
        const Float32* src = (const Float32*)ioMainBuffer;
        Float64 base = inIOCycleInfo->mOutputTime.mSampleTime;
        for(UInt32 f = 0; f < inIOBufferFrameSize; ++f) {
            UInt64 pos = ((UInt64)(base + (Float64)f)) % ringFrames;
            gRingBuffer[pos * kDevice_NumChannels + 0] = src[f * kDevice_NumChannels + 0];
            gRingBuffer[pos * kDevice_NumChannels + 1] = src[f * kDevice_NumChannels + 1];
        }
    } else if(inOperationID == kAudioServerPlugInIOOperationReadInput) {
        // Recording/meeting app reads the virtual mic's input <- ring buffer (loopback).
        Float32* dst = (Float32*)ioMainBuffer;
        Float64 base = inIOCycleInfo->mInputTime.mSampleTime;
        for(UInt32 f = 0; f < inIOBufferFrameSize; ++f) {
            UInt64 pos = ((UInt64)(base + (Float64)f)) % ringFrames;
            dst[f * kDevice_NumChannels + 0] = gRingBuffer[pos * kDevice_NumChannels + 0];
            dst[f * kDevice_NumChannels + 1] = gRingBuffer[pos * kDevice_NumChannels + 1];
        }
    }
    return 0;
}

static OSStatus Crisp_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if(inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}
