//
//  AthanManager.swift
//  Athan Utility
//
//  Created by Omar Al-Ejel on 11/14/20.
//  Copyright © 2020 Omar Alejel. All rights reserved.
//

import Foundation
import Adhan
import CoreLocation
import UIKit
#if !os(watchOS)
import WidgetKit
import AVFoundation
#else
import ClockKit
#endif

import WatchConnectivity

/*
 Athan manager now uses the batoul apps api to calculate prayer times
 Process flow of this manager can roughly be condensed to this list:
 - Current location calculation
 - Use corelocation to find a location name and coordinates
 - Or use manual location input to find coordinates using reversegeocode location
 - Store coordinates on disk, with a flag of whether we want that location to be manual or not
 - Provide accessors to today and tomorrow's prayer times, only recalculating when last calculation day ≠ current day
 - Modify settings for prayer calculation, write changes to user defaults
 - No storage of qibla --> user location angle is enough
 */


// In order to preserve backwards compatibility, properties we would have wanted to observe
// in athan manager are stored in this object, and conditionally updated by AthanManager.s
class ObservableAthanManager: ObservableObject {
    static var shared = ObservableAthanManager()
        
    @Published var todayTimes: PrayerTimes!
    @Published var tomorrowTimes: PrayerTimes!
    @Published var currentPrayer: Prayer! = .fajr
    @Published var locationName: String = ""
    @Published var qiblaHeading: Double = 0.0
    @Published var currentHeading: Double = 0.0
    @Published var locationPermissionsGranted = false
    @Published var appearance: AppearanceSettings = AppearanceSettings.defaultSetting()
}

class AthanManager: NSObject, CLLocationManagerDelegate {
    
    static let shared = AthanManager()
    let locationManager = CLLocationManager()
    var heading: Double = 0.0 {
        didSet {
            ObservableAthanManager.shared.currentHeading = heading
        }
    }
    
    // will default to cupertino times at start of launch
    lazy var todayTimes: PrayerTimes! = nil {
        didSet {
            ObservableAthanManager.shared.todayTimes = self.todayTimes
        }
    }
    
    lazy var tomorrowTimes: PrayerTimes! = nil {
        didSet {
            ObservableAthanManager.shared.tomorrowTimes = self.tomorrowTimes
        }
    }
    
    // MARK: - Settings to load from storage
    var prayerSettings = PrayerSettings.shared {
        didSet { prayerSettingsDidSetHelper() }
    }
    
    var notificationSettings = NotificationSettings.shared {
        didSet { notificationSettingsDidSetHelper() }
    }
    
    var locationSettings = LocationSettings.shared {
        didSet { locationSettingsDidSetHelper() }
    }
    
    var appearanceSettings = AppearanceSettings.shared {
        didSet { appearanceSettingsDidSetHelper() }
    }
    
    var locationPermissionsGranted = false {
        didSet {
            ObservableAthanManager.shared.locationPermissionsGranted = self.locationPermissionsGranted
        }
    }
    var captureLocationUpdateClosure: ((LocationSettings?) -> ())?
    
    // MARK: - DidSet Helpers
    func prayerSettingsDidSetHelper() {
        PrayerSettings.shared = prayerSettings
        PrayerSettings.archive()
        
        // if not running on watchOS, update the watch
        //        #warning("may have unnecessary updates from widget loading up these objects. not sure since i dont think didset is called on widgets unless locations update")
        //        #if !os(watchOS)
        //        if WCSession.default.activationState == .activated {
        //            WCSession.default.sendMessage([PHONE_MSG_KEY : "prayerSettings"]) { replyDict in
        //                print("watchos reply: \(replyDict)")
        //            } errorHandler: { error in
        //                print("> Error with WCSession send")
        //            }
        //        }
        //        #endif
    }
    
    func notificationSettingsDidSetHelper() {
        NotificationSettings.shared = notificationSettings
        NotificationSettings.archive()
        // no need to send these to the watch
    }
    
    func locationSettingsDidSetHelper() {
        //        assert(false, "just checking that this correctly gets called")
        
        let newSettings = LocationSettings.shared.copy() as! LocationSettings // used for reference if we need a comparison for watchOS
        LocationSettings.shared = self.locationSettings
        LocationSettings.archive()
        
        ObservableAthanManager.shared.locationName = self.locationSettings.locationName
        ObservableAthanManager.shared.qiblaHeading = Qibla(coordinates:
                                                            Coordinates(latitude: self.locationSettings.locationCoordinate.latitude,
                                                                        longitude: self.locationSettings.locationCoordinate.longitude)).direction
        #if !os(watchOS)
        if WCSession.default.activationState == .activated && WCSession.default.isReachable {
            do {
                print("*** PHONE SENDING INFO MESSAGE ON LOCATION CHANGE FOR UNREACHABLE WATCH")
                let encoded = try PropertyListEncoder().encode(WatchPackage(locationSettings: self.locationSettings, prayerSettings: self.prayerSettings))
                WCSession.default.sendMessageData(encoded) { (respData) in
                    print(">>> got response from sending watch data")
                } errorHandler: { error in
                    print(">>> error from watch in sending data \(error)")
                }
            } catch {
                print(">>> unable to encode location settings response")
            }
        } else if WCSession.default.activationState == .activated {
            // also a complication update --- TODO: might need to track state for a pending settings change
            // in case we arent activated yet
            
            // read last sent coordinate sent via complication info dict -- dont want very frequent complication updates
            let LAT_KEY = "lastLat"
            let LON_KEY = "lastLon"
            let lastLat = UserDefaults.standard.double(forKey: LAT_KEY)
            let lastLon = UserDefaults.standard.double(forKey: LON_KEY)
            let estimatedLat = Int(lastLat * 100) // compare doubles with precision within 10 degrees
            let estimatedLon = Int(lastLon * 100)
            let comparedLat = Int(newSettings.locationCoordinate.latitude * 100) // must compare against old stored settings
            let comparedLon = Int(newSettings.locationCoordinate.longitude * 100)
            if estimatedLat != comparedLat || estimatedLon != comparedLon {
                // just send something to tell complications to update
                for existingTransfers in WCSession.default.outstandingUserInfoTransfers {
                    existingTransfers.cancel()
                }
                #warning("ensure we dont go over the limit for user info transfers")
                print("*** PHONE SENDING INFO DICT ON LOCATION CHANGE FOR UNREACHABLE WATCH")
                WCSession.default.transferCurrentComplicationUserInfo([
                    "locname" : self.locationSettings.locationName,
                    "latitude" : self.locationSettings.locationCoordinate.latitude,
                    "longitude" : self.locationSettings.locationCoordinate.longitude,
                    "currentloc" : self.locationSettings.useCurrentLocation,
                    "timezoneid" : self.locationSettings.timeZone.identifier
                ])
            }
        } else {
            print(">>>> NOT ACTIVATED")
        }
        #endif
        
        
        // if watchos, we may need to immediately updat ecomplications
        // but we need to be conservative with complication updsates, so confirm that location has changed
        #if os(watchOS)
        let LAT_KEY = "lastLat"
        let LON_KEY = "lastLon"
        let lastLat = UserDefaults.standard.double(forKey: LAT_KEY)
        let lastLon = UserDefaults.standard.double(forKey: LON_KEY)
        let estimatedLat = Int(lastLat * 100) // compare doubles with precision within 10 degrees
        let estimatedLon = Int(lastLon * 100)
        let comparedLat = Int(newSettings.locationCoordinate.latitude * 100) // must compare against old stored settings
        let comparedLon = Int(newSettings.locationCoordinate.longitude * 100)
        // if we have a signficant change in coordinates, save and update all complications
        print("comparing stored and new lats: \(estimatedLat), \(comparedLat)")
        if estimatedLat != comparedLat || estimatedLon != comparedLon {
            refreshTimes()
            
            print(">>> NEW LOCATION \(self.locationSettings.locationName) : update complications!")
            UserDefaults.standard.setValue(Double(self.locationSettings.locationCoordinate.latitude), forKey: LAT_KEY)
            UserDefaults.standard.setValue(Double(self.locationSettings.locationCoordinate.longitude), forKey: LON_KEY)
            
            let complicationServer = CLKComplicationServer.sharedInstance()
            guard let activeComplications = complicationServer.activeComplications else { // watchOS 2.2
                return
            }
            for complication in activeComplications {
                complicationServer.reloadTimeline(for: complication)
            }
        }
        #endif
    }
    
    func appearanceSettingsDidSetHelper() {
        AppearanceSettings.shared = appearanceSettings
        AppearanceSettings.archive()
        ObservableAthanManager.shared.appearance = appearanceSettings
        // no need to send these over to watchos
    }
    
    // App lifecycle state tracking
    private var dayOfMonth = 0
    private var firstLaunch = true
    var currentPrayer: Prayer? {
        didSet {
            DispatchQueue.main.async {
                ObservableAthanManager.shared.currentPrayer = self.currentPrayer! // should never be nil after didSet
            }
        }
    }
    
    override init() {
        super.init()
        
        locationManager.delegate = self
        locationManager.startUpdatingHeading()
        
        #if !os(watchOS)
        // register for going into foreground
        NotificationCenter.default.addObserver(self, selector: #selector(movedToForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        #else
        WCSession.default.delegate = WatchSessionDelegate.shared
        WCSession.default.activate()
        #endif
        
        
        // manually call these the first time since didSet not called on init
        prayerSettingsDidSetHelper()
        notificationSettingsDidSetHelper()
        locationSettingsDidSetHelper()
        
        refreshTimes()
        
        // if non-iOS devices, force a refresh since enteredForeground will not be called
//        if let bundleID = Bundle.main.bundleIdentifier, bundleID != "com.omaralejel.Athan-Utility" {
//            reloadSettingsAndNotifications()
//        }
    }
    
    // safe way to update multiple settings so that all changes propogate to rest of UI
    // this is to avoid recalculating times for two different settings objects that can both
    // modify the times that we get. perhaps the solution was to not have them split up in the first place...
    //    func batchUpdateSettings(prayerSettings: PrayerSettings, notificationSettings: NotificationSettings, locationSettings: LocationSettings) {
    //        self.prayerSettings = prayerSettings
    //        self.notificationSettings = notificationSettings
    //        self.locationSettings = locationSettings // didset handles propogation to observable manager
    //    }
    
    // MARK: - Prayer Times
    
    func refreshTimes() {
        // swiftui publisher gets updates through didSet
        let tz = locationSettings.timeZone
        let adj = notificationSettings.adjustments()
        if let today = calculateTimes(referenceDate: Date(), customTimeZone: tz, adjustments: adj), let tomorrow = calculateTimes(referenceDate: Date().addingTimeInterval(86400), customTimeZone: tz, adjustments: adj) {
            todayTimes = today
            tomorrowTimes = tomorrow
        } else {
            print("DANGER: unable to calculate times. TODO: handle this accordingly for places on the north pole.")
            // default back to settings defaults
            locationSettings = LocationSettings.defaultSetting()
            todayTimes = calculateTimes(referenceDate: Date(), customTimeZone: locationSettings.timeZone, adjustments: adj) // guaranteed fallback
            tomorrowTimes = calculateTimes(referenceDate: Date().addingTimeInterval(86400), customTimeZone: locationSettings.timeZone, adjustments: adj)
        } // should never fail on cupertino time.
        // add 24 hours for next day
        currentPrayer = todayTimes.currentPrayer() ?? .isha
        assert(todayTimes.currentPrayer(at: todayTimes.fajr.addingTimeInterval(-100)) == nil, "failed test on assumption about API nil values")
    }
    
    // NOTE: this function MUST not have SIDE EFFECTS
    func calculateTimes(referenceDate: Date, customCoordinate: CLLocationCoordinate2D? = nil, customTimeZone: TimeZone? = nil, adjustments: PrayerAdjustments?, prayerSettingsOverride: PrayerSettings? = nil) -> PrayerTimes? {
        let coord = locationSettings.locationCoordinate
        
        var cal = Calendar(identifier: Calendar.Identifier.gregorian)
        cal.timeZone = customTimeZone ?? cal.timeZone // if we want to pass a custom time zone not based on the device time zone
        let date = cal.dateComponents([.year, .month, .day], from: referenceDate)
        let coordinates = Coordinates(latitude: customCoordinate?.latitude ?? coord.latitude, longitude: customCoordinate?.longitude ?? coord.longitude)
        
        // Either use override argument or global app settings
        let prayerSettings = prayerSettingsOverride ?? PrayerSettings.shared
        var params = prayerSettings.calculationMethod.params
        params.madhab = prayerSettings.madhab
        params.highLatitudeRule = prayerSettings.latitudeRule
        // custom minute offsets
        if let adjustments = adjustments {
            params.adjustments = adjustments
        }
        
        // handle ummAlQura +30m isha adjustment on ramadan
        // note: add +1day to reference date to account for taraweeh
        //      being on the night before the first day of ramadan
        let hijriCal = Calendar(identifier: .islamicUmmAlQura)
        let islamicComponents = hijriCal.dateComponents([.month], from: referenceDate.addingTimeInterval(24 * 60 * 60))
        if prayerSettings.calculationMethod == .ummAlQura && islamicComponents.month == 9 {
            params.adjustments.isha += 30
        }
        
        if let prayers = PrayerTimes(coordinates: coordinates, date: date, calculationParameters: params) {
            return prayers
        }
        return nil
    }
    
    // MARK: - Timers and timer callbacks
    
    var nextPrayerTimer: Timer?
    var reminderTimer: Timer?
    var newDayTimer: Timer?
    var tenSecondTimer: Timer?
    
    func resetTimers() {
        nextPrayerTimer?.invalidate()
        reminderTimer?.invalidate()
        newDayTimer?.invalidate()
        tenSecondTimer?.invalidate()
        nextPrayerTimer = nil
        reminderTimer = nil
        newDayTimer = nil
        tenSecondTimer = nil
        
        let nextPrayerTime = guaranteedNextPrayerTime()
        
        let secondsLeft = nextPrayerTime.timeIntervalSince(Date())
        nextPrayerTimer = Timer.scheduledTimer(timeInterval: secondsLeft,
                                               target: self, selector: #selector(newPrayer),
                                               userInfo: nil, repeats: false)
        
        // if > 15m and 2 seconds remaining, make a timer
        if secondsLeft > 15 * 60 + 2 {
            reminderTimer = Timer.scheduledTimer(timeInterval: nextPrayerTime.timeIntervalSince(Date()) - 15 * 60,
                                                 target: self, selector: #selector(fifteenMinsLeft),
                                                 userInfo: nil, repeats: false)
        }
        
        // time til next day
        let currentDateComponents = Calendar.current.dateComponents([.hour, .minute, .hour, .second], from: Date())
        let accumulatedSeconds = currentDateComponents.hour! * 60 * 60 + currentDateComponents.minute! * 60 + currentDateComponents.second!
        let remainingSecondsInDay = 86400 - accumulatedSeconds
        print("\(remainingSecondsInDay / 3600) hours left today")
        newDayTimer = Timer.scheduledTimer(timeInterval: TimeInterval(remainingSecondsInDay + 1), // +1 to account for slight error
                                           target: self, selector: #selector(newDay),
                                           userInfo: nil, repeats: false)
    }
    
    private func watchForImminentPrayerUpdate() {
        // enter a background thread loop to wait on a change in case this timer is triggered too early
        let samplePrayer = todayTimes.currentPrayer()
        let nextTime = guaranteedNextPrayerTime()
        let timeUntilChange = nextTime.timeIntervalSince(Date())
        if timeUntilChange < 5 && timeUntilChange > 0 {
            DispatchQueue.global().async {
                // wait on a change
                while (samplePrayer == self.todayTimes.currentPrayer()) {
                    // do nothing
                } // on break, we can update our prayer
                DispatchQueue.main.async {
                    self.currentPrayer = self.todayTimes.currentPrayer() ?? .isha
                }
            }
        } else {
            currentPrayer = todayTimes.currentPrayer() ?? .isha
        }
    }
    
    @objc func newPrayer() {
        //        print("new prayer | \(currentPrayer!) -> \(todayTimes.nextPrayer() ?? .fajr)")
        //        assert(currentPrayer != (todayTimes.nextPrayer() ?? .fajr))
        watchForImminentPrayerUpdate()
    }
    
    @objc func fifteenMinsLeft() {
        // trigger a didset
        //        print("15 mins left | \(currentPrayer!) -> \(todayTimes.nextPrayer() ?? .fajr)")
        //        assert(currentPrayer != todayTimes.nextPrayer() ?? .fajr)
        //        currentPrayer = todayTimes.currentPrayer() ?? .isha
        watchForImminentPrayerUpdate()
    }
    
    @objc func newDay() {
        // will update dayOfMonth
        reloadSettingsAndNotifications()
    }
    
    // MARK: - Helpers
    
    // calculate next prayer, considering next day's .fajr time in case we are on isha time
    func guaranteedNextPrayerTime() -> Date {
        let currentPrayer = todayTimes.currentPrayer()
        // do not use api nextPrayeras it does not distinguish tomorrow fajr from today fajr nil
        //        var nextPrayer: Prayer? = todayTimes.nextPrayer()
        var nextPrayerTime: Date! = nil
        if currentPrayer == .isha { // case for reading from tomorrow fajr times
            nextPrayerTime = tomorrowTimes.fajr
        } else if currentPrayer == nil { // case for reading from today's fajr times
            nextPrayerTime = todayTimes.fajr
        } else { // otherwise, next prayer time is based on today
            nextPrayerTime = todayTimes.time(for: currentPrayer!.next())
        }
        
        return nextPrayerTime
    }
    
    func guaranteedCurrentPrayerTime() -> Date {
        var currentPrayer: Prayer? = todayTimes.currentPrayer()
        var currentPrayerTime: Date! = nil
        if currentPrayer == nil { // case of new day before fajr
            currentPrayer = .isha
            currentPrayerTime = todayTimes.isha.addingTimeInterval(-86400) // shift back today isha approximation by a day
        } else {
            currentPrayerTime = todayTimes.time(for: currentPrayer!)
        }
        return currentPrayerTime
    }
}

// Listen for background events
extension AthanManager {
    func reloadSettingsAndNotifications() {
        // reload settings in case we are running widget and app changed them
        if let arch = LocationSettings.checkArchive() { locationSettings = arch }
        if let arch = NotificationSettings.checkArchive() { notificationSettings = arch }
        if let arch = PrayerSettings.checkArchive() { prayerSettings = arch }
        if let arch = AppearanceSettings.checkArchive() { appearanceSettings = arch }
        
        // unconditional update of day of month
        dayOfMonth = Calendar.current.component(.day, from: Date())
        refreshTimes()
        
        // always make notifications if user has edited from the default location
        if locationSettings.locationName != LocationSettings.defaultSetting().locationName {
            #if !os(watchOS) // dont schedule notes in watchos app
            NotificationsManager
                .createNotifications(coordinate: locationSettings.locationCoordinate,
                                     calculationMethod: prayerSettings.calculationMethod,
                                     madhab: prayerSettings.madhab,
                                     noteSettings: notificationSettings,
                                     shortLocationName: locationSettings.locationName)
            resetWidgets() // should happen when any of our settings change
            #endif
        }
        
        #warning("may no longer need these timers with swiftui timers")
        // reset timers to keep data updated if app stays on screen
        resetTimers()
    }
    
    func resetWidgets() {
        if #available(iOS 14.0, *) {
            // refresh widgets only if this is being run in the main app
            if let bundleID = Bundle.main.bundleIdentifier, bundleID == "com.omaralejel.Athan-Utility" {
                DispatchQueue.main.async {
                    #if !os(watchOS)
                    WidgetCenter.shared.reloadAllTimelines()
                    #endif
                }
            }
        }
    }
    
    // called by observer
    @objc func movedToForeground() {
        print("ENTERED FOREROUND \(Date())")
        // 1. refresh times, notifications, widgets, timers,
        // 2. allow location to be updated and repeat step 1
        // first recalculation on existing location settings
        reloadSettingsAndNotifications() // avoid making new notifications if not needed
        
        if locationSettings.useCurrentLocation {
            attemptSingleLocationUpdate() // if new location is read, we will trigger concsiderRecalculations(isNewLocation: true)
        }
    }
}

// location services side of the manager
extension AthanManager {
    
    // NOTE: leave request to use location data for when the user taps on the loc button OR
    //  if the user launches the app from a widget for the first time
    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    // pass a capture closure to take the location update
    func attemptSingleLocationUpdate(captureClosure: ((LocationSettings?) -> ())? = nil) {
        if let capture = captureClosure {
            self.captureLocationUpdateClosure = capture
        }
        locationManager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == CLAuthorizationStatus.authorizedWhenInUse ||
            status == CLAuthorizationStatus.authorizedAlways {
            #warning("not sure if we should have this automatically called. may want a semaphore")
            locationPermissionsGranted = true
            if locationSettings.useCurrentLocation {
                attemptSingleLocationUpdate()
            }
        } else {
            locationPermissionsGranted = false
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = Double(newHeading.trueHeading)
    }
    
    // triggered and disabled after one measurement
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        self.locationManager.stopUpdatingLocation()
        
        CLGeocoder().reverseGeocodeLocation(locations.first!, completionHandler: { (placemarks: [CLPlacemark]?, error: Error?) -> Void in
            if error == nil {
                print("successfully reverse geocoded location")
                if let placemark = placemarks?.first {
                    let city = placemark.locality
                    let district = placemark.subAdministrativeArea
                    let state = placemark.administrativeArea
                    let country = placemark.isoCountryCode
                    
                    // current preferred method of prioritizing parts of a placemark's location.
                    #warning("test for localization")
                    var shortname = ""
                    if let city = city, let state = state {
                        shortname = "\(city), \(state)"
                    } else if let district = district {
                        shortname = district
                        if let state = state {
                            shortname += ", " + state
                        } else if let country = country {
                            shortname += ", " + country
                        }
                    } else if let name = placemark.name {
                        shortname = name
                    } else {
                        shortname = String(format: "%.2f°, %.2f°", locations.first!.coordinate.latitude, locations.first!.coordinate.longitude)
                    }
                    
                    if placemark.timeZone == nil { print("!!! BAD: time zone for placemark nil")}
                    let timeZone = placemark.timeZone ?? Calendar.current.timeZone
                    // save our location settings
                    let potentialNewLocationSettings = LocationSettings(locationName: shortname,
                                                                        coord: locations.first!.coordinate, timeZone: timeZone, useCurrentLocation: true)
                    
                    if let captureClosue = self.captureLocationUpdateClosure  {
                        captureClosue(potentialNewLocationSettings)
                        self.captureLocationUpdateClosure = nil
                    } else { // if this request is to be considered for storage (not captured in closure):
                        let oldRoundedLat = Int(self.locationSettings.locationCoordinate.latitude * 100)
                        let oldRoundedLon = Int(self.locationSettings.locationCoordinate.longitude * 100)
                        let newRoundedLat = Int(potentialNewLocationSettings.locationCoordinate.latitude * 100)
                        let newRoundedLon = Int(potentialNewLocationSettings.locationCoordinate.longitude * 100)
                        
                        // logical subexpressions qualifying for an update:
                        let sameCoordinate = oldRoundedLat == newRoundedLat && oldRoundedLon == newRoundedLon
                        // MUST check that new placemark is non-nil, otherwise we could be taking in nameless coords
                        let isNewName = placemark.name != nil && potentialNewLocationSettings.locationName != self.locationSettings.locationName
                        //                        if self.locationSettings.locationName != potentialNewLocationSettings.locationName {
                        if !sameCoordinate || (sameCoordinate && isNewName) {
                            // if not same location, OR we now have a placemark name for the location, update location settings
                            self.locationSettings = potentialNewLocationSettings
                            self.reloadSettingsAndNotifications()
                        }
                    }
                    return
                }
            }
            
            // falls through here if we failed to geocode
            
            // user calendar timezone, trusting user is giving coordinates that make sense for their time zone
            let namelessLocationSettings = LocationSettings(locationName: String(format: "%.2f°, %.2f°", locations.first!.coordinate.latitude, locations.first!.coordinate.longitude),
                                                            coord: locations.first!.coordinate, timeZone: Calendar.current.timeZone, useCurrentLocation: true)
            // error case: rely on coordinates and no geocoded name
            if let captureClosue = self.captureLocationUpdateClosure  {
                captureClosue(namelessLocationSettings)
                self.captureLocationUpdateClosure = nil
            } else {
                self.locationSettings = namelessLocationSettings
            }
            
            self.reloadSettingsAndNotifications()
            
            // once done dealing with error, print that we encountered an error
            if let x = error {
                print("failed to reverse geocode location")
                print(x) // fallback
                self.captureLocationUpdateClosure?(nil)
                self.captureLocationUpdateClosure = nil
            }
        })
    }
}
