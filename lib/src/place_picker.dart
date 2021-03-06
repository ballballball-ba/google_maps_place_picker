import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_place_picker/google_maps_place_picker.dart';
import 'package:google_maps_place_picker/providers/place_provider.dart';
import 'package:google_maps_place_picker/src/autocomplete_search.dart';
import 'package:google_maps_place_picker/src/controllers/autocomplete_search_controller.dart';
import 'package:google_maps_place_picker/src/google_map_place_picker.dart';
import 'package:google_maps_place_picker/src/utils/uuid.dart';
import 'package:google_maps_webservice/places.dart';
import 'package:http/http.dart';
import 'package:provider/provider.dart';
import 'dart:io' show Platform;

enum PinState { Preparing, Idle, Dragging }
enum SearchingState { Idle, Searching }

class PlacePicker extends StatefulWidget {
  PlacePicker({
    Key key,
    @required this.apiKey,
    this.onPlacePicked,
    this.initialPosition,
    this.useCurrentLocation,
    this.desiredLocationAccuracy = LocationAccuracy.high,
    this.onMapCreated,
    this.hintText,
    this.searchingText,
    this.searchBarHeight,
    this.contentPadding,
    this.onAutoCompleteFailed,
    this.onGeocodingSearchFailed,
    this.proxyBaseUrl,
    this.httpClient,
    this.selectedPlaceWidgetBuilder,
    this.pinBuilder,
    this.autoCompleteDebounceInMilliseconds = 500,
    this.cameraMoveDebounceInMilliseconds = 750,
    this.initialMapType = MapType.normal,
    this.enableMapTypeButton = true,
    this.enableMyLocationButton = true,
    this.myLocationButtonCooldown = 10,
  }) : super(key: key);

  final String apiKey;

  final LatLng initialPosition;
  final bool useCurrentLocation;
  final LocationAccuracy desiredLocationAccuracy;

  final MapCreatedCallback onMapCreated;

  final String hintText;
  final String searchingText;
  final double searchBarHeight;
  final EdgeInsetsGeometry contentPadding;

  final ValueChanged<String> onAutoCompleteFailed;
  final ValueChanged<String> onGeocodingSearchFailed;
  final int autoCompleteDebounceInMilliseconds;
  final int cameraMoveDebounceInMilliseconds;

  final MapType initialMapType;
  final bool enableMapTypeButton;
  final bool enableMyLocationButton;
  final int myLocationButtonCooldown;

  /// By using default setting of Place Picker, it will result result when user hits the select here button.
  ///
  /// If you managed to use your own [selectedPlaceWidgetBuilder], then this WILL NOT be invoked, and you need use data which is
  /// being sent with [selectedPlaceWidgetBuilder].
  final ValueChanged<PickResult> onPlacePicked;

  /// optional - builds selected place's UI
  ///
  /// It is provided by default if you leave it as a null.
  /// INPORTANT: If this is non-null, [onPlacePicked] will not be invoked, as there will be no default 'Select here' button.
  final SelectedPlaceWidgetBuilder selectedPlaceWidgetBuilder;

  /// optional - builds customized pin widget which indicates current pointing position.
  ///
  /// It is provided by default if you leave it as a null.
  final PinBuilder pinBuilder;

  /// optional - sets 'proxy' value in google_maps_webservice
  ///
  /// In case of using a proxy the baseUrl can be set.
  /// The apiKey is not required in case the proxy sets it.
  /// (Not storing the apiKey in the app is good practice)
  final String proxyBaseUrl;

  /// optional - set 'client' value in google_maps_webservice
  ///
  /// In case of using a proxy url that requires authentication
  /// or custom configuration
  final BaseClient httpClient;

  @override
  _PlacePickerState createState() => _PlacePickerState();
}

class _PlacePickerState extends State<PlacePicker> {
  GlobalKey appBarKey = GlobalKey();
  PlaceProvider provider;
  SearchBarController searchBarController = SearchBarController();

  @override
  void initState() {
    super.initState();

    provider =
        PlaceProvider(widget.apiKey, widget.proxyBaseUrl, widget.httpClient);
    provider.sessionToken = Uuid().generateV4();
    provider.desiredAccuracy = widget.desiredLocationAccuracy;
    provider.setMapType(widget.initialMapType);
  }

  @override
  void dispose() {
    searchBarController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: provider,
      child: Builder(
        builder: (context) {
          return Scaffold(
              extendBodyBehindAppBar: true,
              appBar: AppBar(
                key: appBarKey,
                automaticallyImplyLeading: false,
                iconTheme: Theme.of(context).iconTheme,
                elevation: 0,
                backgroundColor: Colors.transparent,
                titleSpacing: 0.0,
                title: _buildSearchBar(),
              ),
              body: widget.useCurrentLocation
                  ? _buildMapWithLocation()
                  : _buildMap(widget.initialPosition));
        },
      ),
    );
  }

  Widget _buildSearchBar() {
    return Row(
      children: <Widget>[
        IconButton(
            onPressed: () => Navigator.pop(context),
            icon: Icon(
              Platform.isIOS ? Icons.arrow_back_ios : Icons.arrow_back,
            ),
            padding: EdgeInsets.zero),
        Expanded(
          child: AutoCompleteSearch(
            searchBarController: searchBarController,
            sessionToken: provider.sessionToken,
            appBarKey: appBarKey,
            hintText: widget.hintText,
            searchingText: widget.searchingText,
            height: widget.searchBarHeight,
            contentPadding: widget.contentPadding,
            debounceMilliseconds: widget.autoCompleteDebounceInMilliseconds,
            onPicked: (prediction) {
              _pickPrediction(prediction);
            },
            onSearchFailed: (status) {
              if (widget.onAutoCompleteFailed != null) {
                widget.onAutoCompleteFailed(status);
              }
            },
          ),
        ),
        SizedBox(width: 5),
      ],
    );
  }

  _pickPrediction(Prediction prediction) async {
    provider.placeSearchingState = SearchingState.Searching;

    final PlacesDetailsResponse response = await provider.places
        .getDetailsByPlaceId(prediction.placeId,
            sessionToken: provider.sessionToken);

    if (response.errorMessage?.isNotEmpty == true ||
        response.status == "REQUEST_DENIED") {
      print("AutoCompleteSearch Error: " + response.errorMessage);
      if (widget.onAutoCompleteFailed != null) {
        widget.onAutoCompleteFailed(response.status);
      }
      return;
    }

    provider.selectedPlace = PickResult.fromPlaceDetailResult(response.result);

    _moveTo(provider.selectedPlace.geometry.location.lat,
        provider.selectedPlace.geometry.location.lng);

    provider.placeSearchingState = SearchingState.Idle;
  }

  _moveTo(double latitude, double longitude) async {
    GoogleMapController controller = provider.mapController;
    if (controller == null) return;

    await controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(latitude, longitude),
          zoom: 16,
        ),
      ),
    );
  }

  _moveToCurrentPosition() async {
    await _moveTo(
        provider.currentPosition.latitude, provider.currentPosition.longitude);
  }

  Widget _buildMapWithLocation() {
    if (widget.useCurrentLocation) {
      return FutureBuilder(
          future: provider.updateCurrentLocation(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            } else {
              if (provider.currentPosition == null) {
                return _buildMap(widget.initialPosition);
              } else {
                return _buildMap(LatLng(provider.currentPosition.latitude,
                    provider.currentPosition.longitude));
              }
            }
          });
    } else {
      return _buildMap(widget.initialPosition);
    }
  }

  Widget _buildMap(LatLng initialTarget) {
    return GoogleMapPlacePicker(
      initialTarget: initialTarget,
      selectedPlaceWidgetBuilder: widget.selectedPlaceWidgetBuilder,
      pinBuilder: widget.pinBuilder,
      onSearchFailed: widget.onGeocodingSearchFailed,
      debounceMilliseconds: widget.cameraMoveDebounceInMilliseconds,
      enableMapTypeButton: widget.enableMapTypeButton,
      enableMyLocationButton: widget.enableMyLocationButton,
      onMapCreated: widget.onMapCreated,
      onToggleMapType: () {
        provider.switchMapType();
      },
      onMyLocation: () async {
        // Prevent to click many times in short period.
        if (provider.isOnUpdateLocationCooldown == false) {
          provider.isOnUpdateLocationCooldown = true;
          Timer(Duration(seconds: widget.myLocationButtonCooldown), () {
            provider.isOnUpdateLocationCooldown = false;
          });
          await provider.updateCurrentLocation();
          await _moveToCurrentPosition();
        }
      },
      onMoveStart: () {
        searchBarController.reset();
      },
      onPlacePicked: widget.onPlacePicked,
    );
  }
}
