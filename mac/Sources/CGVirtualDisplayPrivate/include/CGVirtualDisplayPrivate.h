// Declarações da API privada CGVirtualDisplay (CoreGraphics).
// É a mesma API usada pelo Sidecar, DeskPad e BetterDisplay para criar
// monitores virtuais. Os símbolos existem em CoreGraphics.framework.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic, copy, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
@property (nonatomic, readonly) unsigned int width;
@property (nonatomic, readonly) unsigned int height;
@property (nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) unsigned int hiDPI;
@property (nonatomic, readonly) NSArray *modes;
@property (nonatomic, readonly) unsigned int maxPixelsWide;
@property (nonatomic, readonly) unsigned int maxPixelsHigh;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
