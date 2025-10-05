package com.example.myapp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetPlugin

class QuoteWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            val widgetData = HomeWidgetPlugin.getData(context)
            val views = RemoteViews(context.packageName, R.layout.quote_widget_layout).apply {
                val quote = widgetData.getString("quote_text", "Cargando refrán...")
                setTextViewText(R.id.quote_text, quote)

                val prevIntent = HomeWidgetBackgroundIntent.getBroadcast(
                    context,
                    Uri.parse("home_widget://update_widget")
                )
                setOnClickPendingIntent(R.id.prev_button, prevIntent)

                val nextIntent = HomeWidgetBackgroundIntent.getBroadcast(
                    context,
                    Uri.parse("home_widget://update_widget")
                )
                setOnClickPendingIntent(R.id.next_button, nextIntent)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
