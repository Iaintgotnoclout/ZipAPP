import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:geoflutterfire2/geoflutterfire2.dart';
import 'package:geolocator/geolocator.dart';
import 'package:zipapp/business/location.dart';
import 'package:zipapp/business/user.dart';
import 'package:zipapp/models/driver.dart';
import 'package:zipapp/models/request.dart';
import 'package:zipapp/models/rides.dart';
import 'package:zipapp/ui/screens/driver_main_screen.dart';
import 'package:intl/intl.dart';

class DriverService {
  static final DriverService _instance = DriverService._internal();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final bool showDebugPrints = true;
  GeoFlutterFire geo = GeoFlutterFire();
  LocationService locationService = LocationService();
  late StreamSubscription<Position> locationSub;
  late CollectionReference driversCollection;
  late DocumentReference driverReference;
  late CollectionReference shiftCollection;
  late DocumentReference shiftReference;
  UserService userService = UserService();
  late List<Driver> nearbyDriversList;
  late Stream<List<Driver>> nearbyDriversListStream;
  late GeoFirePoint myLocation;
  late Driver driver;
  late CurrentShift currentShift;
  StreamSubscription<Driver>? driverSub;
  // Request specific variables
  late CollectionReference requestCollection;
  late Stream<List<Request>> requestStream;
  StreamSubscription<List<Request>>? requestSub;
  late List<Request> currentRequests = [];
  late Request currentRequest;
  bool _isCurrentRideInitialized = false;
  bool _isRequestSubListening = false;
  // Ride specific varaibles
  late Stream<Ride> rideStream;
  StreamSubscription<Ride>? rideSub;
  late Ride currentRide;
  //Shift specific variables
  late String shiftuid;
  int requestLength = 0;

  // Function? uiCallbackFunction;

  HttpsCallable driverClockInFunction =
      FirebaseFunctions.instance.httpsCallable(
    'driverClockIn',
  );

  HttpsCallable driverClockOutFunction =
      FirebaseFunctions.instance.httpsCallable(
    'driverClockOut',
  );

  HttpsCallable driverStartBreakFunction =
      FirebaseFunctions.instance.httpsCallable(
    'driverStartBreak',
  );

  HttpsCallable driverEndBreakFunction =
      FirebaseFunctions.instance.httpsCallable(
    'driverEndBreak',
  );

  HttpsCallable overrideClockInFunction =
      FirebaseFunctions.instance.httpsCallable(
    'overrideClockIn',
  );

  factory DriverService() {
    return _instance;
  }

  // TODO: Update to use user.isDriver before initializing since only driver users will need the service.

  DriverService._internal() {
    if (kDebugMode) {
      print("DriverService Created");
    }
    driversCollection = _firestore.collection('drivers');
    driverReference = driversCollection.doc(userService.userID);
    requestCollection = driverReference.collection('requests');
    shiftCollection = driverReference.collection('shifts');
    shiftuid = DateFormat('MMddyyyy').format(DateTime.now());
  }

  /*
   * Setup the driver service, this will setup the driver service and listen for requests.
   * @return Future<bool> True if the driver service was setup successfully, false otherwise
   */
  Future<bool> setupService() async {
    print('Setting up driver service');
    await _updateDriverRecord();
    driverSub = driverReference
        .snapshots(includeMetadataChanges: true)
        .map((DocumentSnapshot snapshot) {
      return Driver.fromDocument(snapshot);
    }).listen((driver) {
      this.driver = driver;
      if (driver.isWorking && driver.isAvailable && !_isRequestSubListening) {
        startDriving();
        print('Driver is working and available <-----');
      } else {
        // print('Driver is not working or not available');
      }
    });
    //locationSub.cancel();
    locationSub = locationService.positionStream.listen(_updatePosition);
    return true;
  }

  /*
   * Get the driver's current state (isAvailable, isWorking, isOnBreak)
   * @return Map<String, bool> The driver's current state
   */
  Future<Map<String, bool>> getDriverStates() async {
    Map<String, bool> driverStates = {
      'isAvailable': false,
      'isWorking': false,
      'isOnBreak': false
    };
    await FirebaseFirestore.instance
        .collection('drivers')
        .doc(userService.userID)
        .get()
        .then((DocumentSnapshot documentSnapshot) {
          driverStates['isAvailable'] = documentSnapshot.get('isAvailable') ?? false;
          driverStates['isWorking'] = documentSnapshot.get('isWorking') ?? false;
          driverStates['isOnBreak'] = documentSnapshot.get('isOnBreak') ?? false;
        });
    return Future.value(driverStates);
  }

  /*
   * Update the driver's position
   * @param pos The position to update the driver's position to
   * @return void
   */
  void _updatePosition(Position pos) {
    if (driver.isWorking) {
      myLocation = geo.point(
        latitude: pos.latitude, 
        longitude: pos.longitude
      );
      // TODO: Check for splitting driver and position into seperate documents in firebase as an optimization
      driverReference.update({
        'lastActivity': DateTime.now(), 
        'geoFirePoint': myLocation.data
      });
    }
  }

  /*
   * Start the driver service, this will start the driver service and listen for requests.
   * The callback function will be called when the driver service is started.
   * @return void
   */
  void startDriving() async {
    print('Starting driver service');
    driverReference.update({
      'lastActivity': DateTime.now(),
      'geoFirePoint': locationService.getCurrentGeoFirePoint().data,
      'isAvailable': true,
    });
    if (_isRequestSubListening) return;
    initRequestSub();
    await Future.delayed(const Duration(milliseconds: 1000));
  }

  void initRequestSub() {
    // If requestSub is not already listening, start listening
    print('Initiating request subscription');

    if (requestSub != null) return;
    requestStream = requestCollection
      .snapshots()
      .map((event) => event.docs
          .map((e) => Request.fromDocument(e))
          .toList())
      .asBroadcastStream();
    requestSub = requestStream.listen((List<Request> requests) {
      if (requestLength < requests.length) {
        print('New request(s) recieved');
        requestLength = requests.length;
        // Handle the first request
        Request firstRequest = requests.first;
        _onRequestRecieved(firstRequest);
      } else if (requestLength > requests.length) {
        print('Request(s) declined, maybe? But probably not, don\'t worry');
        requestLength = requests.length;
      } else {
        print('No new requests');
        // Do nothing
      }
    });

    _isRequestSubListening = true;
  }

  /*
   * Handle a request that has been recieved, 
   * if the request is not accepted within the timeout period, 
   * it will be declined.
   * @param req The request that has been recieved
   * @return void
   */
  void _onRequestRecieved(Request req) {
    print('Request recieved');
    if (kDebugMode) {
      acceptRequest(req.id); // THIS IS PURELY FOR TESTING PURPOSES, REMOVE IT IF YOU STILL SEE IT HERE DURING PRODUCTION
      print("Request recieved from ${req.name} recieved, timeout at ${req.timeout}");
    }
    currentRequest = req;
    var seconds = (req.timeout.seconds - Timestamp.now().seconds);
    Future.delayed(Duration(seconds: seconds)).then((value) {
      // if (kDebugMode) {
      //   print("Request recieved from ${req.name} timed out");
      // }
      declineRequest(req.id);
    });
  }

  /*
   * Decline a request
   * @param requestID The ID of the request to decline
   * @return void
   */
  Future<void> declineRequest(String requestID) async {
    if (kDebugMode) {
      print("Declining request: $requestID");
    }
    DocumentSnapshot requestRef = await requestCollection.doc(requestID).get();
    if (requestRef.exists) {
      if (kDebugMode) {
        print("Request $requestID exists and will be deleted.");
      }
      await _firestore
          .collection('rides')
          .doc(requestID)
          .update({'status': "SEARCHING"});
      await requestCollection.doc(requestID).delete();
      // uiCallbackFunction!(DriverBottomSheetStatus.searching);
    }
  }

  Future<void> acceptRequest(String requestID) async {
    DocumentSnapshot requestRef = await _firestore.collection('rides').doc(requestID).get();
    rideStream = _firestore
        .collection('rides')
        .doc(requestID)
        .snapshots()
        .map((event) => Ride.fromDocument(event));
    rideSub = rideStream.listen(_onRideUpdate);
    if (requestRef.exists) {
      if (kDebugMode) {
        print(
            "Request $requestID exists and will be deleted after acceptance.");
      }
      await driverReference
          .update({'isAvailable': false, 'currentRideID': requestID});
      await _firestore.collection('rides').doc(requestID).update({
        'status': "IN_PROGRESS",
        'drid': userService.userID,
        'driverName': userService.user.firstName,
        'driverPhotoURL': userService.user.profilePictureURL
      });
      await requestCollection.doc(requestID).delete();
    }
  }

  void stopDriving() {
    print('Stopping driver service');
    driverReference.update({
      'lastActivity': DateTime.now(),
      'currentRideID': '',
      'isAvailable': false,
    });
    // Clear requests from the driver on Firebase
    driverReference.collection('requests').get().then((value) {
      value.docs.map((element) {
        element.reference.delete();
      });
    });
    // Stop listening for requests
    requestSub?.cancel();
    driverSub?.cancel();
    rideSub?.cancel();

    _isRequestSubListening = false;
  }

  void completeRide() async {
    if (currentRide.status != "ENDED") {
      String rideID = driver.currentRideID;
      _addRideToDriver(rideID);
      _addRideToRider(rideID);

      await _firestore.collection('rides').doc(driver.currentRideID).update({
        'lastActivity': DateTime.now(),
        'status': 'ENDED',
        'drid': driver.uid,
        'driverName': "${driver.firstName} ${driver.lastName}",
        'driverPhotoURL': driver.profilePictureURL
      });
    }
    if (kDebugMode) {
      print(driver.uid);
    }
    stopDriving();
  }

  /*
   * Add the ride to the driver's list of past drives
   * @param rideID The ID of the ride to add to the driver's past drives
   * @return void
   */
  void _addRideToDriver(rideID) async {
    if (kDebugMode) {
      print('Adding ride $rideID to driver list of past drives');
    }
    var rideObj = await _firestore.collection('rides').doc(rideID).get();
    var rideDriver = rideObj.get('drid');

    var driverPastDrives =
        (await _firestore.collection('users').doc(rideDriver).get())
            .get('pastDrives');
    driverPastDrives.add(driver.currentRideID);
    await _firestore
        .collection('users')
        .doc(rideDriver)
        .update({'pastDrives': driverPastDrives});
  }

  /*
   * Add the ride to the rider's list of past rides
   * @param rideID The ID of the ride to add to the rider's past rides
   * @return void
   */
  void _addRideToRider(rideID) async {
    if (kDebugMode) {
      print('Adding ride $rideID to rider list of past rides');
    }
    var rideObj = await _firestore.collection('rides').doc(rideID).get();
    var rideRider = rideObj.get('uid');
    var riderPastRides =
        (await _firestore.collection('users').doc(rideRider).get())
            .get('pastRides');
    riderPastRides.add(rideID);
    await _firestore
        .collection('users')
        .doc(rideRider)
        .update({'pastRides': riderPastRides});
  }

  /*
   * Cancel the current ride
   * @return void
   */
  void cancelRide() async {
    if (!_isCurrentRideInitialized) return;
    if (currentRide.status != "CANCELED") {
      await _firestore.collection('rides').doc(driver.currentRideID).update({
        'lastActivity': DateTime.now(),
        'status': 'CANCELED',
      });
    }
  }

  void _onRideUpdate(Ride updatedRide) {
    try {
      if (currentRide.status == updatedRide.status) return;
    } catch (e) {
      // do nothing
    }
    print("Updated ride status to ${updatedRide.status}");
    currentRide = updatedRide;
    _isCurrentRideInitialized = true;
    switch (updatedRide.status) {
      case 'CANCELED':
        cancelRide();
        startDriving();
        if (showDebugPrints) {
          if (kDebugMode) {
            print("Ride is canceled");
          }
        }
        break;
      case 'IN_PROGRESS':
        if (showDebugPrints) {
          if (kDebugMode) {
            print("Ride is now IN_PROGRESS");
          }
        }
        break;
      case 'ENDED':
        startDriving();
        if (showDebugPrints) {
          if (kDebugMode) {
            print("Ride has ended.");
          }
        }
        break;
      default:
    }
  }

  Stream<Driver> getDriverStream() {
    return driverReference
        .snapshots(includeMetadataChanges: true)
        .map((snapshot) {
      return Driver.fromDocument(snapshot);
    });
  }

  Stream<CurrentShift> getCurrentShift() {
    return shiftReference
        .snapshots(includeMetadataChanges: true)
        .map((snapshot) {
      return CurrentShift.fromDocument(snapshot);
    });
  }

  // TODO: Audit
  Stream<List<Driver>> getNearbyDriversStream() {
    nearbyDriversListStream = geo
          .collection(collectionRef: driversCollection)
          .within(center: myLocation, radius: 50, field: 'geoFirePoint')
          .map((snapshots) =>
              snapshots.map((e) => Driver.fromDocument(e)).take(10).toList());
    return nearbyDriversListStream;
  }

  Future<List<Driver>> getNearbyDriversListWithModel(double radius, String cartModel) async {
    GeoFirePoint centerPoint = locationService.getCurrentGeoFirePoint();
    print(driver.cartModel);
    Query collectionReference =
        _firestore.collection('drivers')
        .where('isAvailable', isEqualTo: true)
        .where('cartModel', isEqualTo: cartModel);

    Stream<List<Driver>> stream = geo
        .collection(collectionRef: collectionReference)
        .within(
            center: centerPoint,
            radius: radius,
            field: 'geoFirePoint',
            strictMode: false)
        .map((event) =>
            event.map((e) => Driver.fromDocument(e)).take(10).toList());

    List<Driver> nearbyDrivers = await stream.first;
    nearbyDrivers.forEach((driver) {
      print("${driver.firstName} is available and in range.");
    });
    return nearbyDrivers;
  }

  _updateDriverRecord() async {
    DocumentSnapshot myDriverRef = await driverReference.get();
    if (!myDriverRef.exists) {
      driversCollection.doc(userService.userID).set({
        'uid': userService.userID,
        'firstName': userService.user.firstName,
        'lastName': userService.user.lastName,
        'cartModel': "X",
        'profilePictureURL': userService.user.profilePictureURL,
        'geoFirePoint': locationService.getCurrentGeoFirePoint().data,
        'lastActivity': DateTime.now(),
        'isAvailable': false,
        'isWorking': false,
        'isOnBreak': false,
        'daysOfWeek': [],
      }, SetOptions(merge: true)).then((_) {
        print("Successfully started ride.");
      }).catchError((error) {
        print("Error starting ride: $error");
      });
    } else {
      // TODO: Get rid of once server is constantly checking for abandoned drivers
      // stopDriving();
    }
  }

  /*
   * Clock in the driver
   * @return Future<Map<String, dynamic>> The result of the clock in operation
   */
  Future<Map<String, dynamic>> clockIn() async {
    print(driver.daysOfWeek);
    HttpsCallableResult result = await driverClockInFunction.call(<String, dynamic>{
      'daysOfWeek': driver.daysOfWeek,
      'driveruid': driver.uid,
      'shiftuid': shiftuid
    });
    print(result.data);
    String response = result.data['response'];
    bool success = result.data['success'];

    return {'success': success, 'response': response};
  }

  /*
   * Clock out the driver
   * @return Future<Map<String, dynamic>> The result of the clock out operation
   */
  Future<Map<String, dynamic>> clockOut() async {
    HttpsCallableResult result = await driverClockOutFunction.call(
        <String, dynamic>{'driveruid': driver.uid, 'shiftuid': shiftuid});
    print(result.data);
    String response = (result.data['response']).toString();
    bool success = result.data['success'];

    return {'success': success, 'response': response};
  }

  /*
   * Start the driver's break
   * @return Future<Map<String, dynamic>> The result of the start break operation
   */
  Future<Map<String, dynamic>> startBreak() async {
    HttpsCallableResult result = await driverStartBreakFunction.call(
        <String, dynamic>{'driveruid': driver.uid, 'shiftuid': shiftuid});
    print(result.data);
    String response = (result.data['response']).toString();
    bool success = result.data['success'];

    return {'response': response, 'success': success};
  }

  /*
   * End the driver's break
   * @return Future<Map<String, dynamic>> The result of the end break operation
   */
  Future<Map<String, dynamic>> endBreak() async {
    HttpsCallableResult result = await driverEndBreakFunction.call(
        <String, dynamic>{'driveruid': driver.uid, 'shiftuid': shiftuid});
    print(result.data);
    String response = (result.data['response']).toString();
    bool success = result.data['success'];

    return {'success': success, 'response': response};
  }
  
  // I'm gonna be honest I dont know what the purpose of this was supposed to be
  Future<String> overrideClockIn() async {
    late String message;
    try {
      HttpsCallableResult result = await overrideClockInFunction.call(
          <String, dynamic>{'driveruid': driver.uid, 'shiftuid': shiftuid});

      message = (result.data['response']).toString();
    } catch (e) {
      if (kDebugMode) {
        print("Error overriding clock in");
      }
    }
    return message;
  }
}
