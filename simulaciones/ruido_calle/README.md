# Simulación: Filtro de Ruido de Calle

Simulación offline del pipeline DSP completo con señal de voz + ruido de calle.

## Objetivo

Validar que el filtro de ruido (GTCRN) atenúa el ruido urbano preservando la inteligibilidad de la voz, sin necesidad del celular.

## Contenido (por crear)

- `generar_entrada.py` — genera WAV de voz + ruido a SNR controlado
- `procesar.cpp` — compila el motor C++ como CLI y procesa el WAV
- `medir_salida.py` — compara salida vs voz limpia (SNR, PESQ, STOI)
- `entrada/` — WAVs de entrada (voz limpia, ruido, mezcla)
- `salida/` — WAVs procesados por el pipeline
