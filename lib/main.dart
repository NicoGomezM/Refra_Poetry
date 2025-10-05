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

import 'quotes_es.dart';

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
  Future<Map<String, String>> fetchQuote([String language = 'en']) async {
    if (language == 'es') {
      final random = Random();
      final quote = quotes_es[random.nextInt(quotes_es.length)];
      return {
        'content': quote['text']!,
        'author': quote['from']!,
      };
    }
    final response = await http.get(Uri.parse('https://zenquotes.io/api/random'));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final quoteData = data[0];
      return {
        'content': quoteData['q'],
        'author': quoteData['a'],
      };
    } else {
      throw Exception('Failed to load quote');
    }
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
