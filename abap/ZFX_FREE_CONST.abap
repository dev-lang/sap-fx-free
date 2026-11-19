*&---------------------------------------------------------------------*
*& Include ZFX_FREE_CONST
*&---------------------------------------------------------------------*
*& SAP FX Free - Constantes comunes de ZFX_FREE_LOAD y ZFX_FREE_FETCH.
*& Fuente única: cualquier cambio de estas fechas se hace solo acá.
*&
*& Compatibilidad: SAP_BASIS 731.
*& Versión 1.0 - 19.11.2026 (fecha mínima)
*& Versión 1.1 - 19.11.2026 (tabla de cortes de escala, lcl_fx_cuts)
*&---------------------------------------------------------------------*

CONSTANTS:
* Fecha mínima de cotización (ZFX_FREE_LOAD). El peso tiene curso legal
* desde el 01.01.1992, con $1 = A 10.000 (Decreto 2128/91, arts. 1 y 2).
* Lo anterior es austral: no se reexpresa ni se carga (queda OMITIDO).
  gc_min_date     TYPE d VALUE '19920101',
* Primera fecha que acepta la API del BCRA (ZFX_FREE_FETCH). Verificado
* el 19.11.2026: hasta el 01.01.1992 inclusive responde HTTP 400; el
* 02.01.1992 trae solo USD.
  gc_api_min_date TYPE d VALUE '19920102'.

*----------------------------------------------------------------------*
* Cortes de escala (redenominaciones)
*
* El BCRA publica valores nominales con el código actual: el VES de
* 2003 es el bolívar de 2003 (VEB), con otra escala. Cada entrada dice
* en qué rango de fechas BCRA el valor corresponde a la moneda SAP
* WAERS. Fuera de ese rango la línea queda OMITIDA en ZFX_FREE_LOAD.
*
* - valid_from / valid_to: fechas del BCRA (no las oficiales). Vacías =
*   sin límite. Ej.: el BCRA aplicó el cambio de VES de 2021 recién el
*   04.10.2021 (el 01.10, fecha oficial, todavía publicó escala vieja).
* - Entre el 21.08.2018 y el 01.10.2021 el valor del BCRA no corresponde
*   a ninguna moneda SAP (VES con la escala de 2018): queda omitido.
* - official, factor, verified, checked_on: documentales. verified = X
*   si el salto se midió en la serie del BCRA; vacío = protección con la
*   fecha oficial (hoy no actúa: el corte es anterior a la serie).
*----------------------------------------------------------------------*
TYPES: BEGIN OF ty_fx_cut,
         waers      TYPE c LENGTH 5,   " moneda SAP
         bcra       TYPE c LENGTH 5,   " código en la API del BCRA
         valid_from TYPE d,            " primera fecha BCRA válida
         valid_to   TYPE d,            " última fecha BCRA válida
         official   TYPE d,            " fecha oficial del cambio
         factor     TYPE i,            " unidades viejas por una nueva
         verified   TYPE c LENGTH 1,   " X = verificado en la serie
         checked_on TYPE d,            " fecha de verificación
       END OF ty_fx_cut,
       ty_t_fx_cut TYPE STANDARD TABLE OF ty_fx_cut WITH DEFAULT KEY.

CLASS lcl_fx_cuts DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS get
      RETURNING value(rt_cuts) TYPE ty_t_fx_cut.
ENDCLASS.                    "lcl_fx_cuts DEFINITION

CLASS lcl_fx_cuts IMPLEMENTATION.
  METHOD get.
    DATA ls_cut TYPE ty_fx_cut.

*   Bolívar: verificado en la serie del BCRA el 19.11.2026
    CLEAR ls_cut.
    ls_cut-waers      = 'VEB'.
    ls_cut-bcra       = 'VEB'.
    ls_cut-valid_to   = '20071228'.
    ls_cut-official   = '20080101'.
    ls_cut-factor     = 1000.
    ls_cut-verified   = 'X'.
    ls_cut-checked_on = '20261119'.
    APPEND ls_cut TO rt_cuts.

    CLEAR ls_cut.
    ls_cut-waers      = 'VEF'.
    ls_cut-bcra       = 'VEB'.
    ls_cut-valid_from = '20080102'.
    ls_cut-valid_to   = '20180817'.
    ls_cut-official   = '20180820'.
    ls_cut-factor     = 100000.
    ls_cut-verified   = 'X'.
    ls_cut-checked_on = '20261119'.
    APPEND ls_cut TO rt_cuts.

    CLEAR ls_cut.
    ls_cut-waers      = 'VES'.
    ls_cut-bcra       = 'VEB'.
    ls_cut-valid_from = '20211004'.
    ls_cut-official   = '20211001'.
    ls_cut-factor     = 1000000.
    ls_cut-verified   = 'X'.
    ls_cut-checked_on = '20261119'.
    APPEND ls_cut TO rt_cuts.

*   Protección con la fecha oficial (el BCRA no tiene datos de la
*   moneda vieja en la serie; hoy no actúan)
    CLEAR ls_cut.
    ls_cut-waers      = 'TRY'.
    ls_cut-bcra       = 'TRY'.
    ls_cut-valid_from = '20050101'.
    ls_cut-official   = '20050101'.
    ls_cut-factor     = 1000000.
    ls_cut-checked_on = '20261119'.
    APPEND ls_cut TO rt_cuts.

    CLEAR ls_cut.
    ls_cut-waers      = 'RUB'.
    ls_cut-bcra       = 'RUB'.
    ls_cut-valid_from = '19980101'.
    ls_cut-official   = '19980101'.
    ls_cut-factor     = 1000.
    ls_cut-checked_on = '20261119'.
    APPEND ls_cut TO rt_cuts.

    CLEAR ls_cut.
    ls_cut-waers      = 'BRL'.
    ls_cut-bcra       = 'BRL'.
    ls_cut-valid_from = '19940701'.
    ls_cut-official   = '19940701'.
    ls_cut-factor     = 2750.
    ls_cut-checked_on = '20261119'.
    APPEND ls_cut TO rt_cuts.

    CLEAR ls_cut.
    ls_cut-waers      = 'UYU'.
    ls_cut-bcra       = 'UYU'.
    ls_cut-valid_from = '19930301'.
    ls_cut-official   = '19930301'.
    ls_cut-factor     = 1000.
    ls_cut-checked_on = '20261119'.
    APPEND ls_cut TO rt_cuts.

    CLEAR ls_cut.
    ls_cut-waers      = 'MXN'.
    ls_cut-bcra       = 'MXP'.
    ls_cut-valid_from = '19930101'.
    ls_cut-official   = '19930101'.
    ls_cut-factor     = 1000.
    ls_cut-checked_on = '20261119'.
    APPEND ls_cut TO rt_cuts.
  ENDMETHOD.                    "get
ENDCLASS.                    "lcl_fx_cuts IMPLEMENTATION
