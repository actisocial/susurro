---
name: banco
description: Corre el banco de calidad de Susurro sobre los 46 casos y compara el resultado contra la referencia, para decidir si un cambio en la limpieza del texto mejoró o empeoró.
argument-hint: "[id de modelo de refinado, opcional]"
allowed-tools: Bash, Read, Grep
---

# Banco de calidad

Los tests verdes no alcanzan para juzgar un cambio en `Susurro/Sources/Refine/`.
Pasó una vez: un cambio en las muletillas inglesas dejó los 54 tests en verde y
hundió el F1 de borrado en inglés de 90 % a 58 %. Lo agarró el banco. Por eso
este flujo existe aparte de `make test`.

## Cómo correrlo

El binario tiene que estar compilado. Si no lo está, `make build` primero — la
primera vez tarda unos 20 minutos.

```
build/dd/Build/Products/Release/Susurro.app/Contents/MacOS/Susurro --bench
```

Con un modelo de refinado distinto del configurado:

```
… --bench --modelo-refinado <id>
```

Los ids salen de `RefinementCatalog.all` en
`Susurro/Sources/Refine/RefinementModels.swift`.

## Qué mirar

La salida trae una fila por idioma —`es`, `en`, `mix`, `heavy`— y un `TOTAL`.
`heavy` son dictados largos con los dos idiomas entreverados: es la fila que se
rompe primero y la que más dice.

Referencia actual, con Qwen3.5 2B 8-bit en un M2 Pro:

| métrica | valor |
|---|---|
| puntuación F1 | 82 % |
| borrado F1 | 85 % |
| borrado, precisión | 98 % |
| p50 | 928 ms |
| rechazos / fuera de tiempo | 0 / 0 |

**La precisión de borrado es la que manda.** Por debajo de 95 % el modelo está
borrando palabras que hacen falta, y eso es destruir significado — mucho peor que
puntuar mal. Si bajó, el cambio está mal aunque el F1 total haya subido.

Un aumento de rechazos o de timeouts tampoco es ruido: un refinado que no llega a
tiempo no da un resultado peor, da **cero** resultado, porque se inserta el texto
sin puntuar.

## Al reportar

Comparar contra la referencia de arriba fila por fila, y decir explícitamente qué
empeoró aunque el total haya mejorado. Si una fila cae fuerte, revisar si es
calidad o latencia antes de concluir: son causas distintas con el mismo síntoma.

El banco es sensible a la carga de la máquina. Si hay otra cosa pesada corriendo
en paralelo, la latencia miente — y una latencia que miente arrastra a las demás
métricas, porque los casos que se pasan de tiempo cuentan como sin refinar.
