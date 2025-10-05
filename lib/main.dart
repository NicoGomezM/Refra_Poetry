import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:myapp/notification_service.dart';
import 'dart:developer' as developer;
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';

// ahora las frases se obtienen desde el backend (API) que lee la BD

// Función para manejar las actualizaciones del widget en segundo plano
void backgroundCallback(Uri? uri) async {
  if (uri?.host == 'update_widget') {
    final quote = await QuoteService().fetchQuote();
    HomeWidget.saveWidgetData<String>('quote_text', '"${quote["content"]}" - ${quote["author"]}' );
    HomeWidget.updateWidget(
        name: 'QuoteWidgetProvider',
        iOSName: 'QuoteWidgetProvider',
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HomeWidget.registerBackgroundCallback(backgroundCallback);
  try {
    final NotificationService notificationService = NotificationService();
    await notificationService.init();
    await notificationService.scheduleDailyQuoteNotification();
  } catch (e, s) {
    developer.log('Error initializing notifications', error: e, stackTrace: s);
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => ThemeProvider()),
        ChangeNotifierProvider(create: (context) => QuoteProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

// ThemeProvider para gestionar el estado del tema (claro/oscuro)
class ThemeProvider with ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  void toggleTheme() {
    _themeMode =
        _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }
}

// QuoteService para obtener los refranes de la API
class QuoteService {
  // Soporte para MongoDB Atlas Data API vía --dart-define
  // Debes pasar estas variables en build: MONGO_DATA_API_URL, MONGO_DATA_API_KEY, MONGO_DATA_SOURCE
  // Ejemplo:
  // flutter build apk --release \
  //   --dart-define=MONGO_DATA_API_URL="https://data.mongodb-api.com/app/<app-id>/endpoint/data/v1" \
  //   --dart-define=MONGO_DATA_API_KEY="<your_api_key>" \
  //   --dart-define=MONGO_DATA_SOURCE="Cluster0"
  static const String _dataApiUrl = String.fromEnvironment('MONGO_DATA_API_URL', defaultValue: '');
  static const String _dataApiKey = String.fromEnvironment('MONGO_DATA_API_KEY', defaultValue: '');
  static const String _dataApiSource = String.fromEnvironment('MONGO_DATA_SOURCE', defaultValue: '');
  static const String _dataApiDb = String.fromEnvironment('MONGO_DATA_API_DB', defaultValue: 'refra_poetry');
  static const String _dataApiCollection = String.fromEnvironment('MONGO_DATA_API_COLLECTION', defaultValue: 'phrases');

  // Fallback a hosts locales si no está configurada la Data API
  static const String _apiHostFromDefine = String.fromEnvironment('API_HOST', defaultValue: '');
  final List<String> _hosts = [
    if (_apiHostFromDefine.isNotEmpty) _apiHostFromDefine,
    'http://10.0.2.2:8000',
    'http://localhost:8000',
  ];

  Future<Map<String, String>> fetchQuote([String language = 'en']) async {
    // Si se suministró Data API URL + key + source, usar directa Data API de Atlas
    if (_dataApiUrl.isNotEmpty && _dataApiKey.isNotEmpty && _dataApiSource.isNotEmpty) {
      try {
        final uri = Uri.parse('$_dataApiUrl/action/aggregate');
        final body = json.encode({
          'dataSource': _dataApiSource,
          'database': _dataApiDb,
          'collection': _dataApiCollection,
          'pipeline': [
            {'\u0024match': {'language': language}},
            {'\u0024sample': {'size': 1}}
          ]
        });
        final response = await http.post(uri,
            headers: {
              'Content-Type': 'application/json',
              'api-key': _dataApiKey,
            },
            body: body).timeout(const Duration(seconds: 7));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final docs = data['documents'] as List<dynamic>?;
          if (docs != null && docs.isNotEmpty) {
            final doc = docs.first as Map<String, dynamic>;
            return {
              'content': (doc['text'] ?? '') as String,
              'author': (doc['author'] ?? 'Desconocido') as String,
            };
          } else {
            throw Exception('No documents returned by Data API');
          }
        } else {
          throw Exception('Data API error: ${response.statusCode} ${response.body}');
        }
      } catch (e) {
        // En caso de fallo con Data API, seguimos a intentar endpoints locales
      }
    }

    // Si no hay Data API configurada o falló, probar los hosts locales/API propia
    for (final host in _hosts) {
      final uri = Uri.parse('$host/quote?language=$language');
      try {
        final response = await http.get(uri).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          return {
            'content': data['content'] ?? '',
            'author': data['author'] ?? 'Desconocido',
          };
        }
      } catch (e) {
        // ignora y prueba el siguiente host
      }
    }

    throw Exception('No se pudo conectar al servidor de frases');
  }
}

// QuoteProvider para gestionar el estado de los refranes
class QuoteProvider with ChangeNotifier {
  final QuoteService _quoteService = QuoteService();
  Map<String, String> _quote = {
    'content': 'Presiona el botón para cargar un refrán.',
    'author': 'IA',
  };
  bool _isLoading = false;
  final List<Map<String, String>> _favorites = [];
  String _language = 'en';

  Map<String, String> get quote => _quote;
  bool get isLoading => _isLoading;
  List<Map<String, String>> get favorites => _favorites;
  String get language => _language;

  QuoteProvider() {
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    _language = prefs.getString('language') ?? 'en';
    notifyListeners();
    fetchQuote();
  }

  Future<void> setLanguage(String language) async {
    _language = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', language);
    notifyListeners();
    fetchQuote();
  }

  Future<void> fetchQuote() async {
    _isLoading = true;
    notifyListeners();
    try {
      _quote = await _quoteService.fetchQuote(_language);
      HomeWidget.saveWidgetData<String>('quote_text', '"${_quote["content"]}" - ${_quote["author"]}' );
      HomeWidget.updateWidget(
          name: 'QuoteWidgetProvider',
          iOSName: 'QuoteWidgetProvider',
      );
    } catch (e) {
      _quote = {
        'content': 'No se pudo cargar el refrán. Inténtalo de nuevo.',
        'author': 'Error',
      };
    }
    _isLoading = false;
    notifyListeners();
  }

  bool isFavorite(Map<String, String> quote) {
    return _favorites.any((favorite) => favorite['content'] == quote['content']);
  }

  void toggleFavorite(Map<String, String> quote) {
    if (isFavorite(quote)) {
      _favorites.removeWhere((favorite) => favorite['content'] == quote['content']);
    } else {
      _favorites.add(quote);
    }
    notifyListeners();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const Color primarySeedColor = Colors.teal;

    final TextTheme appTextTheme = TextTheme(
      displayLarge: GoogleFonts.pacifico(
          fontSize: 34, fontWeight: FontWeight.bold, letterSpacing: 1.2),
      titleLarge: GoogleFonts.lato(fontSize: 22, fontWeight: FontWeight.w600),
      bodyMedium: GoogleFonts.openSans(fontSize: 16, height: 1.5),
      labelLarge: GoogleFonts.lato(fontSize: 16, fontWeight: FontWeight.bold),
    );

    final ThemeData lightTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primarySeedColor,
        brightness: Brightness.light,
      ),
      textTheme: appTextTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: primarySeedColor,
        foregroundColor: Colors.white,
        titleTextStyle:
            GoogleFonts.lato(fontSize: 20, fontWeight: FontWeight.bold),
      ),
    );

    final ThemeData darkTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primarySeedColor,
        brightness: Brightness.dark,
      ),
      textTheme: appTextTheme,
    );

    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          title: 'Reflexiones Diarias',
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeProvider.themeMode,
          home: const HomePage(),
        );
      },
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reflexiones Diarias'),
        actions: [
          const LanguageSelector(),
          IconButton(
            icon: const Icon(Icons.favorite),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const FavoritesPage()),
              );
            },
            tooltip: 'Favoritos',
          ),
          IconButton(
            icon: Icon(
              Provider.of<ThemeProvider>(context).themeMode == ThemeMode.dark
                  ? Icons.light_mode
                  : Icons.dark_mode,
            ),
            onPressed: () =>
                Provider.of<ThemeProvider>(context, listen: false)
                    .toggleTheme(),
            tooltip: 'Cambiar Tema',
          ),
        ],
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: QuoteDisplay(),
        ),
      ),
      floatingActionButton: const RefreshButton(),
    );
  }
}

class LanguageSelector extends StatelessWidget {
  const LanguageSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final quoteProvider = Provider.of<QuoteProvider>(context);

    return DropdownButton<String>(
      value: quoteProvider.language,
      icon: const Icon(Icons.language, color: Colors.white),
      dropdownColor: Colors.teal,
      underline: Container(),
      onChanged: (String? newValue) {
        if (newValue != null) {
          quoteProvider.setLanguage(newValue);
        }
      },
      items: <String>['en', 'es'].map<DropdownMenuItem<String>>((String value) {
        return DropdownMenuItem<String>(
          value: value,
          child: Text(
            value.toUpperCase(),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        );
      }).toList(),
    );
  }
}

class QuoteDisplay extends StatelessWidget {
  const QuoteDisplay({super.key});

  @override
  Widget build(BuildContext context) {
    final quoteProvider = Provider.of<QuoteProvider>(context);
    final quote = quoteProvider.quote;
    final isLoading = quoteProvider.isLoading;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isLoading)
          const CircularProgressIndicator()
        else
          Column(
            children: [
              Text(
                '"${quote['content']}""',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      fontSize: 28,
                    ),
              ),
              const SizedBox(height: 20),
              Text(
                '- ${quote['author']}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              IconButton(
                icon: Icon(
                  quoteProvider.isFavorite(quote)
                      ? Icons.favorite
                      : Icons.favorite_border,
                  color: Colors.red,
                  size: 30,
                ),
                onPressed: () {
                  quoteProvider.toggleFavorite(quote);
                },
              ),
            ],
          ),
      ],
    );
  }
}

class RefreshButton extends StatelessWidget {
  const RefreshButton({super.key});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: () =>
          Provider.of<QuoteProvider>(context, listen: false).fetchQuote(),
      tooltip: 'Nuevo Refrán',
      child: const Icon(Icons.refresh),
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis Favoritos'),
      ),
      body: Consumer<QuoteProvider>(
        builder: (context, quoteProvider, child) {
          final favorites = quoteProvider.favorites;
          if (favorites.isEmpty) {
            return const Center(
              child: Text('Aún no tienes refranes favoritos.'),
            );
          }
          return ListView.builder(
            itemCount: favorites.length,
            itemBuilder: (context, index) {
              final quote = favorites[index];
              return ListTile(
                title: Text('"${quote['content']}"'),
                subtitle: Text('- ${quote['author']}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () {
                    quoteProvider.toggleFavorite(quote);
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
