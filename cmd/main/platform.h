#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

double as_monotonic_ms(void);
NSString *as_utc_now(void);
NSError *as_failure(NSString *message);
NSString *as_data_directory(void);
id _Nullable as_ble_request(NSDictionary *_Nonnull input,
                            NSError *_Nullable *_Nonnull error);
id _Nullable as_service_request(NSDictionary *_Nonnull input,
                                NSError *_Nullable *_Nonnull error);
id _Nullable as_registry_request(NSDictionary *_Nonnull input,
                                 NSError *_Nullable *_Nonnull error);

NS_ASSUME_NONNULL_END
