#import "CGVirtualDisplayPrivate.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

static void SVSetNumber(CFMutableDictionaryRef d, CFStringRef key, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

int SVUSBReenumerateADBDevice(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostInterface");
    if (!match) return -1;
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
    SVSetNumber(props, CFSTR("bInterfaceClass"), 255);
    SVSetNumber(props, CFSTR("bInterfaceSubClass"), 66);
    SVSetNumber(props, CFSTR("bInterfaceProtocol"), 1);
    CFDictionarySetValue(match, CFSTR("IOPropertyMatch"), props);
    CFRelease(props);

    io_service_t iface = IOServiceGetMatchingService(kIOMainPortDefault, match); // consome "match"
    if (!iface) return -1;
    io_registry_entry_t device = 0;
    kern_return_t kr = IORegistryEntryGetParentEntry(iface, kIOServicePlane, &device);
    IOObjectRelease(iface);
    if (kr != KERN_SUCCESS) return kr;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kr = IOCreatePlugInInterfaceForService(device, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                           &plugin, &score);
    IOObjectRelease(device);
    if (kr != KERN_SUCCESS || !plugin) return kr ? kr : -1;

    IOUSBDeviceInterface650 **dev = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    (*plugin)->Release(plugin);
    if (!dev) return -1;

    kern_return_t opened = (*dev)->USBDeviceOpenSeize(dev);
    kr = (*dev)->USBDeviceReEnumerate(dev, 0);
    if (opened == kIOReturnSuccess) (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return kr;
}
