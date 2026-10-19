# Guía de usuario de LumaTrace

LumaTrace organiza fotos y vídeos locales sin mover los archivos originales. Esta guía corresponde a la versión actual para macOS 14 o posterior.

## Primer inicio

1. Abre LumaTrace y elige **Carpetas vigiladas** en la barra lateral.
2. Añade una o varias carpetas y concede acceso cuando macOS lo solicite.
3. Pulsa **Iniciar** en los controles de análisis. La esquina inferior izquierda muestra la ruta y la fase actuales. Los elementos aparecen a medida que terminan de analizarse.
4. En **Ajustes**, configura el idioma, el análisis de vídeo, Ollama local opcional y los recuerdos programados.

El índice y las miniaturas se guardan localmente. LumaTrace no mueve ni modifica los originales. Quitar una carpeta detiene su supervisión, pero conserva sus archivos y los registros existentes.

## Explorar, buscar y previsualizar

Usa las secciones de la barra lateral para ver todos los elementos, fotos, vídeos, fotos en movimiento, lugares, Time Travel o duplicados. La búsqueda usa etiquetas, texto reconocido y descripciones disponibles.

Haz clic en una miniatura para abrir la vista previa. Desliza horizontalmente para cambiar de elemento, pellizca en el trackpad para ampliar y arrastra para desplazarte cuando haya zoom. La tira de miniaturas permite elegir otro elemento. El botón de información abre un panel lateral que puedes cerrar y desde el que puedes añadir una ubicación. La pantalla completa es opcional.

Mantén el puntero sobre una miniatura durante cinco segundos para mostrar una vista ampliada. Solo el elemento seleccionado conserva el borde azul.

## Lugares y etiquetas de ubicación

La página Lugares muestra un mapa de OpenStreetMap incluso si ningún elemento tiene GPS. Los elementos con GPS aparecen como marcadores; el nivel de zoom cambia su agrupación. También puedes seleccionar elementos y asignar una ciudad, distrito o ubicación más concreta. La búsqueda de lugares requiere Internet. Las solicitudes de mapas revelan al proveedor el área aproximada visible; consulta [Privacidad](PRIVACY.md).

## Análisis de vídeo y reintentos

El modo predeterminado analiza fotogramas de muestra. El análisis profundo puede decodificar más fotogramas y tardar bastante. Los vídeos con códecs dañados o no compatibles pueden fallar. En **Necesita reintento**, puedes volver a analizar una carpeta o todos los elementos fallidos. Si hay un análisis activo, la solicitud queda en cola.

Si un vídeo falla repetidamente, comprueba que se reproduce en un reproductor actualizado de macOS. Si es necesario, convierte una copia a H.264. Conserva el original hasta verificar la copia.

## Duplicados y recuerdos

Los duplicados exactos y los elementos similares se agrupan por separado. Las sugerencias incluyen un motivo; revisa los elementos antes de eliminarlos. LumaTrace no borra duplicados automáticamente.

Time Travel permite crear un recuerdo manualmente o programarlo a diario o en días concretos. Solo utiliza archivos disponibles e indexados. Los vídeos se generan y guardan localmente. El reposo, apagado o cierre de sesión pueden retrasar la programación. Las notificaciones requieren permiso de macOS.

## Solución de problemas

- **Carpeta no disponible:** conecta el disco y actualiza la carpeta.
- **Pocos elementos:** el recuento refleja los archivos indexados; inicia o actualiza un análisis para descubrir contenido nuevo.
- **Mapa vacío:** comprueba la conexión; los mapas usan mosaicos en línea.
- **Modelo local no disponible:** inicia Ollama, instala un modelo visual compatible y comprueba la conexión en Ajustes.
- **Aviso al instalar:** las compilaciones locales no están firmadas ni notarizadas por Apple.

Consulta [Privacidad](PRIVACY.md) y [Testing notes](TESTING.md).
