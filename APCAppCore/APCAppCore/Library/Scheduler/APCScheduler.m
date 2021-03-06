// 
//  APCScheduler.m 
//  APCAppCore 
// 
// Copyright (c) 2015, Apple Inc. All rights reserved. 
// 
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
// 
// 1.  Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
// 
// 2.  Redistributions in binary form must reproduce the above copyright notice, 
// this list of conditions and the following disclaimer in the documentation and/or 
// other materials provided with the distribution. 
// 
// 3.  Neither the name of the copyright holder(s) nor the names of any contributors 
// may be used to endorse or promote products derived from this software without 
// specific prior written permission. No license is granted to the trademarks of 
// the copyright holders even if such marks are included in this software. 
// 
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE 
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR 
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, 
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE 
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
// 
 

#import "APCScheduler.h"
#import "APCAppCore.h"
#import "APCDateRange.h"

static NSString * const kOneTimeSchedule = @"once";

@interface APCScheduler()
@property  (weak, nonatomic)     APCDataSubstrate        *dataSubstrate;
@property  (strong, nonatomic)   NSManagedObjectContext  *scheduleMOC;
@property  (nonatomic) BOOL isUpdating;


@property (nonatomic, strong) NSDateFormatter * dateFormatter;

//Properties that need to be cleaned after every upate
@property (nonatomic, strong) NSMutableArray * allScheduledTasksForReferenceDate;
@property (nonatomic, strong) NSMutableArray * validatedScheduledTasksForReferenceDate;

@end

@implementation APCScheduler

- (NSDateFormatter *)dateFormatter {
    if (_dateFormatter == nil) {
        _dateFormatter = [NSDateFormatter new];
        [_dateFormatter setDateStyle:NSDateFormatterMediumStyle];
        [_dateFormatter setTimeStyle:NSDateFormatterMediumStyle];
    }
    return _dateFormatter;
}

- (instancetype)initWithDataSubstrate: (APCDataSubstrate*) dataSubstrate
{
    self = [super init];
    if (self) {
        self.dataSubstrate = dataSubstrate;
        self.scheduleMOC = self.dataSubstrate.persistentContext;
    }
    return self;
}

- (void)updateScheduledTasksIfNotUpdating: (BOOL) today
{
    [self updateScheduledTasksIfNotUpdatingWithRange:today? kAPCSchedulerDateRangeToday : kAPCSchedulerDateRangeTomorrow];
}

-(void)updateScheduledTasksIfNotUpdatingWithRange:(APCSchedulerDateRange)range
{
    if (!self.isUpdating) {
        self.isUpdating = YES;
        switch (range) {
            case kAPCSchedulerDateRangeYesterday:
                self.referenceRange = [APCDateRange yesterdayRange];
                break;
            case kAPCSchedulerDateRangeToday:
                self.referenceRange = [APCDateRange todayRange];
                break;
                
            case kAPCSchedulerDateRangeTomorrow:
                self.referenceRange = [APCDateRange tomorrowRange];
                break;
        }
        [self updateScheduledTasks];
    }
}

- (void) updateScheduledTasks
{
    [self.scheduleMOC performBlockAndWait:^{
        
        //STEP 1: Update inActive property of schedules based on endOn date.
        [self updateSchedulesAsInactiveIfNecessary];
        
        //STEP 2: Disable one time tasks if they are already completed
        [self disableOneTimeTasksIfAlreadyCompleted];
        
        //STEP 3: Get all the current scheduled tasks relevant to reference daterange
        [self filterAllScheduledTasksInReferenceDate];
        
        //STEP 4: Update scheduled tasks
        [self updateScheduledTasksBasedOnActiveSchedules];
        
        //STEP 5: Validate all completed tasks
        [self validateAllCompletedTasks];
        
        //STEP 6: Delete non-validated schedules
        [self deleteAllNonvalidatedScheduledTasks];
        
        //STEP 7: Issue notifications that we've completed a survey
        [[NSNotificationCenter defaultCenter]postNotificationName:APCUpdateTasksReminderNotification object:nil];
        
        self.isUpdating = NO;
        APCLogEventWithData(kSchedulerEvent, (@{@"event_detail":[NSString stringWithFormat:@"Updated Schedule For %@", self.referenceRange.startDate]}));
    }];
}

/*********************************************************************************/
#pragma mark - Methods Inside MOC
/*********************************************************************************/
- (void) updateSchedulesAsInactiveIfNecessary
{
    NSFetchRequest * request = [APCSchedule request];
    NSDate * lastEndOnDate = [NSDate yesterdayAtMidnight];
    NSDate * earliestStartOnDate = [NSDate endOfDay:[NSDate tomorrowAtMidnight]];
    request.predicate = [NSPredicate predicateWithFormat:@"(endsOn <= %@) || (startsOn > %@)", lastEndOnDate, earliestStartOnDate];
    NSError * error;
    NSArray * array = [self.scheduleMOC executeFetchRequest:request error:&error];
    APCLogError2 (error);
    [array enumerateObjectsUsingBlock:^(APCSchedule * schedule, NSUInteger __unused idx, BOOL * __unused stop) {
        schedule.inActive = @(YES);
        NSError * saveError;
        [schedule saveToPersistentStore:&saveError];
        APCLogError2 (saveError);
    }];
}

- (void) disableOneTimeTasksIfAlreadyCompleted
{
    //List remoteupdatable, one time tasks
    NSFetchRequest * request = [APCSchedule request];
    request.predicate = [NSPredicate predicateWithFormat:@"remoteUpdatable == %@ && scheduleType == %@", @(YES), kOneTimeSchedule];
    NSError * error;
    NSArray * scheduleArray = [self.scheduleMOC executeFetchRequest:request error:&error];
    APCLogError2 (error);
    
    //Get completed scheduled tasks with that one time task. If they exist make the schedule inactive
    [scheduleArray enumerateObjectsUsingBlock:^(APCSchedule * obj, NSUInteger __unused idx, BOOL * __unused stop) {
        NSFetchRequest * request = [APCScheduledTask request];
        request.predicate = [NSPredicate predicateWithFormat:@"completed == %@ && task.taskID == %@", @(YES), obj.taskID];
        NSError * error;
        NSArray * scheduledTaskArray = [self.scheduleMOC executeFetchRequest:request error:&error];
        if (scheduledTaskArray.count > 0) { obj.inActive = @(YES);}
        APCLogError2 (error);
    }];
    
    APCSchedule * lastSchedule = [scheduleArray lastObject];
    NSError * saveError;
    [lastSchedule saveToPersistentStore:&saveError];
    APCLogError2 (saveError);
}

- (void) filterAllScheduledTasksInReferenceDate {
    NSFetchRequest * request = [APCScheduledTask request];
    NSDate * startOfDay = [NSDate startOfDay:self.referenceRange.startDate];
    request.predicate = [NSPredicate predicateWithFormat:@"endOn > %@", startOfDay];
    NSError * error;
    NSArray * array = [self.scheduleMOC executeFetchRequest:request error:&error];
    APCLogError2 (error);
    NSMutableArray * filteredArray = [NSMutableArray array];
    
    for (APCScheduledTask * scheduledTask in array) {
        if ([scheduledTask.dateRange compare:self.referenceRange] != kAPCDateRangeComparisonOutOfRange) {
            [filteredArray addObject:scheduledTask];
        }
    }
    self.allScheduledTasksForReferenceDate = filteredArray;
}

- (void) updateScheduledTasksBasedOnActiveSchedules
{
    NSArray * activeSchedules = [self readActiveSchedules];
    [activeSchedules enumerateObjectsUsingBlock:^(APCSchedule * schedule, NSUInteger __unused idx, BOOL * __unused stop) {
        [self updateScheduledTasksForSchedule:schedule];
    }];
}

- (NSArray*) readActiveSchedules
{
    NSFetchRequest * request = [APCSchedule request];
    NSDate * lastStartOnDate = [NSDate startOfTomorrow:self.referenceRange.startDate];
    request.predicate = [NSPredicate predicateWithFormat:@"(inActive == nil || inActive == %@) && (startsOn == nil || startsOn < %@)", @(NO), lastStartOnDate];
    NSError * error;
    NSArray * array = [self.scheduleMOC executeFetchRequest:request error:&error];
    APCLogError2 (error);
    return array.count ? array : nil;
}

-(NSArray *) allScheduledTasks{
    __block NSArray * scheduledTaskArray;
    NSFetchRequest * request = [APCScheduledTask request];
    [request setShouldRefreshRefetchedObjects:YES];
    NSError * error;
    scheduledTaskArray = [self.scheduleMOC executeFetchRequest:request error:&error];
    if (scheduledTaskArray.count == 0) {
        APCLogError2 (error);
    }
    
    return scheduledTaskArray;
}


- (void) updateScheduledTasksForSchedule: (APCSchedule*) schedule
{
    APCTask * task = [APCTask taskWithTaskID:schedule.taskID inContext:self.scheduleMOC];
    NSAssert(task,@"Task is nil");
    if (schedule.isOneTimeSchedule) {
        [self findOrCreateOneTimeScheduledTask:schedule task:task];
    }
    else
    {
        APCScheduleExpression * scheduleExpression = schedule.scheduleExpression;
        NSDate * beginningTime = (schedule.expires !=nil) ? [self.referenceRange.startDate dateByAddingTimeInterval:(-1*schedule.expiresInterval)] : self.referenceRange.startDate;
        
        NSEnumerator*   enumerator = [scheduleExpression enumeratorBeginningAtTime:beginningTime endingAtTime:self.referenceRange.endDate];
        NSDate * startOnDate;
        while ((startOnDate = enumerator.nextObject))
        {
            APCDateRange * range;
            BOOL doFindOrCreate = NO;
            if (schedule.expires != nil) {
                range = [[APCDateRange alloc] initWithStartDate:startOnDate durationInterval:schedule.expiresInterval];
                if ([range compare:self.referenceRange] != kAPCDateRangeComparisonOutOfRange) {
                    doFindOrCreate = YES;
                }
                else {
                    APCLogDebug(@"Created out of range dateRange: %@ for %@", range, task.taskTitle);
                }
            }
            else {
                range = [[APCDateRange alloc] initWithStartDate:startOnDate endDate:self.referenceRange.endDate];
                doFindOrCreate = YES;
            }
            if (doFindOrCreate) {
                [self findOrCreateRecurringScheduledTask:schedule task:task dateRange:range];
            }
        }
    }
}

- (void) validateAllCompletedTasks
{
    NSArray * filteredArray = [self.allScheduledTasksForReferenceDate filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"completed == %@", @YES]];
    
    [self.validatedScheduledTasksForReferenceDate addObjectsFromArray:filteredArray];
    [self.allScheduledTasksForReferenceDate removeObjectsInArray:filteredArray];
}

/*********************************************************************************/
#pragma mark - One Time Task Find Or Create
/*********************************************************************************/
- (void) findOrCreateOneTimeScheduledTask:(APCSchedule *) schedule task: (APCTask*) task {

     NSArray * scheduledTasksArray = [[self allScheduledTasks] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"task.taskID == %@", task.taskID]];
    
    if (scheduledTasksArray.count > 0){
        APCLogDebug(@"task already scheduled: %@", task);
        APCScheduledTask * validatedTask = scheduledTasksArray.firstObject;
        [self validateScheduledTask:validatedTask];
    }else{
        //One time not created, create it        
        NSDate *startOnDate = [self.referenceRange.startDate startOfDay];
        
        NSDate * endDate = (schedule.expires !=nil) ? [startOnDate dateByAddingTimeInterval:schedule.expiresInterval] : [startOnDate dateByAddingTimeInterval:[NSDate parseISO8601DurationString:@"P2Y"]];
        endDate = [NSDate endOfDay:endDate];
        [self createScheduledTask:schedule task:task dateRange:[[APCDateRange alloc] initWithStartDate:startOnDate endDate:endDate]];
    }
}

- (void) findOrCreateOneTimeScheduledTask:(APCSchedule *) schedule task: (APCTask*) task andStartDateReference: (NSDate *)startOn {
    
    NSArray * scheduledTasksArray = [[self allScheduledTasks] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"task.taskID == %@", task.taskID]];
    
    if (scheduledTasksArray.count > 0){
        APCLogDebug(@"task already scheduled: %@", task);
        APCScheduledTask * validatedTask = scheduledTasksArray.firstObject;
        [self validateScheduledTask:validatedTask];
    }else{
        //One time not created, create it
        NSDate *startOnDate = [startOn startOfDay];
        
        NSDate * endDate = (schedule.expires !=nil) ? [startOnDate dateByAddingTimeInterval:schedule.expiresInterval] : [startOnDate dateByAddingTimeInterval:[NSDate parseISO8601DurationString:@"P2Y"]];
        endDate = [NSDate endOfDay:endDate];
        [self createScheduledTask:schedule task:task dateRange:[[APCDateRange alloc] initWithStartDate:startOnDate endDate:endDate]];
    }
    
}

/*********************************************************************************/
#pragma mark - Recurring Task Find or Create
/*********************************************************************************/
- (void) findOrCreateRecurringScheduledTask: (APCSchedule*) schedule task: (APCTask*) task dateRange: (APCDateRange*) range {
    
    NSArray * scheduledTasksArray = [self.allScheduledTasksForReferenceDate filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"task == %@", task]];
    
    NSMutableArray * filteredArray = [NSMutableArray array];
    [scheduledTasksArray enumerateObjectsUsingBlock:^(APCScheduledTask * scheduledTask, NSUInteger __unused idx, BOOL * __unused stop) {
        if ([scheduledTask.dateRange compare:range] == kAPCDateRangeComparisonSameRange) {
            [filteredArray addObject:scheduledTask];
        }
    }];
    
    if (filteredArray.count == 0) {
        //Schedule not created, create it
        [self createScheduledTask:schedule task:task dateRange:range];
    }
    else if (filteredArray.count == 1) {
        APCScheduledTask * validatedTask = filteredArray.firstObject;
        [self validateScheduledTask:validatedTask];
    }
    else {
        APCLogError(@"Many recurring scheduled tasks %@ present with the exact same range: %@", task.taskTitle, range);
    }
}

/*********************************************************************************/
#pragma mark - Helpers
/*********************************************************************************/
- (void) createScheduledTask:(APCSchedule*) schedule task: (APCTask*) task dateRange: (APCDateRange*) dateRange
{
    APCAppDelegate * appDelegate = (APCAppDelegate*)[UIApplication sharedApplication].delegate;
    
    NSArray *offsetsForTask = [appDelegate offsetForTaskSchedules];
    
    
    
    APCScheduledTask * createdScheduledTask = [APCScheduledTask newObjectForContext:self.scheduleMOC];
    
    NSDate *taskStartDate = dateRange.startDate;
    NSDate *taskEndDate = dateRange.endDate;

    
    NSPredicate *predicate = nil;
    NSArray *matchedTasks = nil;
    NSNumber *daysToOffset = nil;
    NSString *currentTaskID = nil;
    NSDate *offsetStartDate = nil;
    NSDate *todaysDate = [NSDate todayAtMidnight];
    
    if (offsetsForTask) {
        predicate = [NSPredicate predicateWithFormat:@"%K == %@", kScheduleOffsetTaskIdKey, task.taskID];
        matchedTasks = [offsetsForTask filteredArrayUsingPredicate:predicate];
        daysToOffset = nil;
        
        if (matchedTasks.count > 0) {
            daysToOffset = [[matchedTasks firstObject] valueForKey:kScheduleOffsetOffsetKey];
            currentTaskID = [[matchedTasks firstObject] valueForKey:kScheduleOffsetTaskIdKey];
        }
        
    }
    
    if (daysToOffset) {
        NSDateComponents *components = [[NSDateComponents alloc] init];
        [components setDay:[daysToOffset integerValue]];
        
        offsetStartDate = [[NSCalendar currentCalendar] dateByAddingComponents:components
                                                                        toDate:task.createdAt
                                                                       options:0];
        
        offsetStartDate = [offsetStartDate startOfDay];
        
        APCLogDebug(@"Task %@ scheduled offset by %lu days. New start date is %@", task.taskTitle, [daysToOffset integerValue], taskStartDate);
    }
    
    if (([task.taskID isEqualToString:currentTaskID] && currentTaskID != nil)
        && (([offsetStartDate isEqualToDate:todaysDate]) ||
            ([[todaysDate laterDate:offsetStartDate] isEqualToDate:todaysDate])))
    {
        
        createdScheduledTask.startOn = taskStartDate;
        createdScheduledTask.endOn = taskEndDate;
        createdScheduledTask.generatedSchedule = schedule;
        createdScheduledTask.task = task;
        
        NSError * saveError = nil;
        BOOL saveSuccess = [createdScheduledTask saveToPersistentStore:&saveError];
        
        if (!saveSuccess) {
            APCLogError2 (saveError);
        }
        
        //Validate the task
        [self.validatedScheduledTasksForReferenceDate addObject:createdScheduledTask];
        
    } else if (daysToOffset == nil || daysToOffset <= 0) {
        createdScheduledTask.startOn = taskStartDate;
        createdScheduledTask.endOn = taskEndDate;
        createdScheduledTask.generatedSchedule = schedule;
        createdScheduledTask.task = task;
        
        NSError * saveError = nil;
        BOOL saveSuccess = [createdScheduledTask saveToPersistentStore:&saveError];
        
        if (!saveSuccess) {
            APCLogError2 (saveError);
        }
        
        //Validate the task
        [self.validatedScheduledTasksForReferenceDate addObject:createdScheduledTask];
    } else {
        APCLogDebug(@"Nothing should be happening here!");
    }
}

- (void) validateScheduledTask: (APCScheduledTask*) scheduledTask {
    [self.validatedScheduledTasksForReferenceDate addObject:scheduledTask];
    [self.allScheduledTasksForReferenceDate removeObject:scheduledTask];
}

- (void) deleteAllNonvalidatedScheduledTasks {
    while (self.allScheduledTasksForReferenceDate.count) {
        APCScheduledTask * task = [self.allScheduledTasksForReferenceDate lastObject];
        [self.allScheduledTasksForReferenceDate removeLastObject];
        [task deleteScheduledTask];
    }
}

@end
