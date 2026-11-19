*&---------------------------------------------------------------------*
*& Include ZFX_FREE_CONST
*&---------------------------------------------------------------------*
*& SAP FX Free - Constantes comunes de ZFX_FREE_LOAD y ZFX_FREE_FETCH.
*& Fuente única: cualquier cambio de estas fechas se hace solo acá.
*&
*& Compatibilidad: SAP_BASIS 731.
*& Versión 1.0 - 19.11.2026 (fecha mínima)
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
