//
//  DeviceModel.m
//  PeoPleMusic
//
//  Created by Alen on 16/3/17.
//  Copyright © 2016年 kyo. All rights reserved.
//

#import "DeviceModel.h"

@implementation DeviceModel
+ (NSDictionary *)dictDeviceWithModel:(DeviceModel *)model{
    if (!model) {
        model = [[DeviceModel alloc] init];
        model.deviceId = @"";
        model.deviceVersion = @"";
    }
    return [model keyValues];
}
@end
