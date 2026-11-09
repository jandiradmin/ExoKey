// Private XCTest classes for precise multi-touch timing (the same ones WebDriverAgent uses).
#import <UIKit/UIKit.h>

@interface XCPointerEventPath : NSObject
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
@end

@interface XCSynthesizedEventRecord : NSObject
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(UIInterfaceOrientation)orientation;
- (void)addPointerEventPath:(XCPointerEventPath *)path;
- (BOOL)synthesizeWithError:(NSError **)error;
@end
