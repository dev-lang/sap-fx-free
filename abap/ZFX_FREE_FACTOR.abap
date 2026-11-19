*&---------------------------------------------------------------------*
*& Report ZFX_FREE_FACTOR
*&---------------------------------------------------------------------*
*& SAP FX Free - Cambio de factores de conversión (OBBS / V_TCURF) con
*& análisis de impacto sobre las cotizaciones existentes (TCURR).
*&
*& Para qué: un factor nuevo cambia cómo se leen las cotizaciones del
*& par desde su fecha (TCURR guarda FFACT/TFACT en 0; el factor sale de
*& TCURF a la fecha de conversión). Antes de crear factores, este
*& programa muestra qué cotizaciones cambiarían de lectura y bloquea el
*& cambio si alguna queda mal.
*&
*& Reglas de diseño:
*&  - Nunca escribe directo en TCURF/TCURR: usa batch input sobre SM30
*&    (V_TCURF), igual que ZFX_FREE_SETUP, y registra en la orden de
*&    customizing indicada.
*&  - Modo SIMULACIÓN por defecto: solo lee TCURF, TCURR, TCURC, TCURV.
*&  - No modifica ni borra factores existentes. Misma fecha con otros
*&    valores: se rechaza.
*&  - Bloquea si (a) alguna cotización existente cambia de lectura, o
*&    (b) un cambio de factor no tiene una cotización de esa misma fecha
*&    habiendo cotizaciones anteriores (regla del incidente MXN: las
*&    conversiones desde esa fecha usarían una cotización cargada con
*&    el factor anterior).
*&  - Los factores se crean en orden de fecha descendente y se corta en
*&    el primer error. Cada alta se verifica releyendo TCURF.
*&
*& Compatibilidad: SAP_BASIS 731 (sin sintaxis 7.40+).
*& Versión 1.0 - 19.11.2026
*&---------------------------------------------------------------------*
REPORT zfx_free_factor.

TYPE-POOLS: abap, icon.

*----------------------------------------------------------------------*
* Tipos
*----------------------------------------------------------------------*
TYPES: BEGIN OF ty_fac,
         datum  TYPE d,                 " válido desde
         ffact  TYPE tcurf-ffact,
         tfact  TYPE tcurf-tfact,
         origin TYPE c LENGTH 1,        " E existente, N nuevo
       END OF ty_fac,
       ty_t_fac TYPE STANDARD TABLE OF ty_fac WITH DEFAULT KEY.

TYPES: BEGIN OF ty_new,
         idx     TYPE i,                " fila de la pantalla (1-3)
         datum   TYPE d,
         ffact   TYPE tcurf-ffact,
         tfact   TYPE tcurf-tfact,
         status  TYPE c LENGTH 1,       " ver gc_st_*
         message TYPE string,
       END OF ty_new,
       ty_t_new TYPE STANDARD TABLE OF ty_new WITH DEFAULT KEY.

TYPES: BEGIN OF ty_rate,
         datum TYPE d,
         ukurs TYPE tcurr-ukurs,
       END OF ty_rate,
       ty_t_rate TYPE STANDARD TABLE OF ty_rate WITH DEFAULT KEY.

TYPES: BEGIN OF ty_out,
         icon      TYPE icon_d,
         fila      TYPE c LENGTH 14,
         estado    TYPE c LENGTH 15,
         fecha     TYPE d,
         ff_act    TYPE tcurf-ffact,
         tf_act    TYPE tcurf-tfact,
         ff_new    TYPE tcurf-ffact,
         tf_new    TYPE tcurf-tfact,
         cotiz     TYPE tcurr-ukurs,
         val_act   TYPE p LENGTH 16 DECIMALS 9,
         val_new   TYPE p LENGTH 16 DECIMALS 9,
         mensaje   TYPE c LENGTH 255,
       END OF ty_out,
       ty_t_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

CONSTANTS:
  gc_st_new  TYPE c LENGTH 1 VALUE 'A',  " para crear
  gc_st_same TYPE c LENGTH 1 VALUE 'E',  " ya existe igual: nada que hacer
  gc_st_rej  TYPE c LENGTH 1 VALUE 'R',  " rechazado (bloquea)
  gc_st_done TYPE c LENGTH 1 VALUE 'L',  " creado y verificado
  gc_st_fail TYPE c LENGTH 1 VALUE 'F',  " falló el batch input
  gc_st_skip TYPE c LENGTH 1 VALUE 'S',  " no procesado (corte por error)
* TCURF/TCURR-GDATU guardan la fecha invertida (99999999 - AAAAMMDD)
  gc_inv     TYPE c LENGTH 20 VALUE '09182736455463728190'.

*----------------------------------------------------------------------*
* Pantalla de selección
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b01 WITH FRAME TITLE t_b01.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_kurst FOR FIELD p_kurst.
PARAMETERS p_kurst TYPE tcurf-kurst DEFAULT 'M' OBLIGATORY.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_fcurr FOR FIELD p_fcurr.
PARAMETERS p_fcurr TYPE tcurf-fcurr OBLIGATORY.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_tcurr FOR FIELD p_tcurr.
PARAMETERS p_tcurr TYPE tcurf-tcurr DEFAULT 'ARS' OBLIGATORY.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b01.

SELECTION-SCREEN BEGIN OF BLOCK b02 WITH FRAME TITLE t_b02.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(12) c_h1.
SELECTION-SCREEN COMMENT 14(12) c_h2.
SELECTION-SCREEN COMMENT 28(12) c_h3.
SELECTION-SCREEN COMMENT 42(12) c_h4.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(12) c_r1.
PARAMETERS: p_d1  TYPE d,
            p_ff1 TYPE tcurf-ffact,
            p_tf1 TYPE tcurf-tfact.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(12) c_r2.
PARAMETERS: p_d2  TYPE d,
            p_ff2 TYPE tcurf-ffact,
            p_tf2 TYPE tcurf-tfact.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(12) c_r3.
PARAMETERS: p_d3  TYPE d,
            p_ff3 TYPE tcurf-ffact,
            p_tf3 TYPE tcurf-tfact.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b02.

SELECTION-SCREEN BEGIN OF BLOCK b03 WITH FRAME TITLE t_b03.
SELECTION-SCREEN BEGIN OF LINE.
PARAMETERS p_sim RADIOBUTTON GROUP mod DEFAULT 'X'.
SELECTION-SCREEN COMMENT 4(70) c_sim FOR FIELD p_sim.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
PARAMETERS p_real RADIOBUTTON GROUP mod.
SELECTION-SCREEN COMMENT 4(70) c_real FOR FIELD p_real.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_trkorr FOR FIELD p_trkorr.
PARAMETERS p_trkorr TYPE e070-trkorr.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_mode FOR FIELD p_mode.
PARAMETERS p_mode(1) TYPE c DEFAULT 'N'.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
PARAMETERS p_all AS CHECKBOX.
SELECTION-SCREEN COMMENT 4(70) c_all FOR FIELD p_all.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b03.

*----------------------------------------------------------------------*
* Clase principal
*----------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS run.

  PRIVATE SECTION.
    DATA: mt_new     TYPE ty_t_new,
          mt_cur     TYPE ty_t_fac,       " factores actuales (TCURF)
          mt_plan    TYPE ty_t_fac,       " actuales + nuevos a crear
          mt_rates   TYPE ty_t_rate,      " cotizaciones del par (TCURR)
          mt_out     TYPE ty_t_out,
          mt_bdc     TYPE STANDARD TABLE OF bdcdata,
          mv_result  TYPE string,
          mv_block   TYPE abap_bool,      " hay algo que bloquea
          mv_n_new   TYPE i,              " factores para crear
          mv_n_aff   TYPE i,              " cotizaciones que cambian
          mv_n_cut   TYPE i,              " cortes sin cotización
          mv_n_done  TYPE i.

    METHODS check_input
      RETURNING value(rv_error) TYPE string.
    METHODS read_sap.
    METHODS build_plan.
    METHODS analyze.
    METHODS check_cuts.
    METHODS factor_at
      IMPORTING it_list  TYPE ty_t_fac
                iv_date  TYPE d
      EXPORTING ev_ffact TYPE tcurf-ffact
                ev_tfact TYPE tcurf-tfact
                ev_found TYPE abap_bool.
    METHODS unit_value
      IMPORTING iv_ukurs        TYPE tcurr-ukurs
                iv_ffact        TYPE tcurf-ffact
                iv_tfact        TYPE tcurf-tfact
      RETURNING value(rv_value) TYPE ty_out-val_act.
    METHODS check_request
      RETURNING value(rv_error) TYPE string.
    METHODS can_execute
      RETURNING value(rv_ok) TYPE abap_bool.
    METHODS execute.
    METHODS create_factor
      CHANGING cs_new TYPE ty_new.
    METHODS call_sm30
      EXPORTING ev_text TYPE string.
    METHODS bdc_dynpro
      IMPORTING iv_program TYPE csequence
                iv_dynpro  TYPE csequence.
    METHODS bdc_field
      IMPORTING iv_fnam TYPE csequence
                iv_fval TYPE csequence.
    METHODS add_out
      IMPORTING iv_icon   TYPE icon_d
                iv_fila   TYPE csequence
                iv_estado TYPE csequence
                iv_text   TYPE string.
    METHODS build_output.
    METHODS display.

    CLASS-METHODS inv_to_date
      IMPORTING iv_inv         TYPE tcurf-gdatu
      RETURNING value(rv_date) TYPE d.
    CLASS-METHODS date_to_inv
      IMPORTING iv_date       TYPE d
      RETURNING value(rv_inv) TYPE tcurf-gdatu.
    CLASS-METHODS fmt_int
      IMPORTING iv_int         TYPE i
      RETURNING value(rv_text) TYPE string.
    CLASS-METHODS fmt_date
      IMPORTING iv_date        TYPE d
      RETURNING value(rv_text) TYPE string.
    CLASS-METHODS fmt_fac
      IMPORTING iv_ffact       TYPE tcurf-ffact
                iv_tfact       TYPE tcurf-tfact
      RETURNING value(rv_text) TYPE string.
    CLASS-METHODS add_msg
      IMPORTING iv_text TYPE string
      CHANGING  cv_msg  TYPE string.
    CLASS-METHODS set_col
      IMPORTING io_cols  TYPE REF TO cl_salv_columns_table
                iv_name  TYPE lvc_fname
                iv_long  TYPE scrtext_l
                iv_med   TYPE scrtext_m
                iv_short TYPE scrtext_s.
ENDCLASS.                    "lcl_app DEFINITION

DATA go_app TYPE REF TO lcl_app.

*----------------------------------------------------------------------*
* Eventos
*----------------------------------------------------------------------*
INITIALIZATION.
  t_b01    = 'Par de monedas'.
  t_b02    = 'Factores nuevos (hasta 3; fila vacía = no se usa)'.
  t_b03    = 'Ejecución'.
  c_kurst  = 'Tipo de cotización'.
  c_fcurr  = 'Moneda origen'.
  c_tcurr  = 'Moneda destino'.
  c_h1     = ''.
  c_h2     = 'Válido desde'.
  c_h3     = 'Factor de'.
  c_h4     = 'Factor a'.
  c_r1     = 'Factor 1'.
  c_r2     = 'Factor 2'.
  c_r3     = 'Factor 3'.
  c_sim    = 'Simulación: analiza el impacto, no modifica SAP'.
  c_real   = 'Ejecución real: crea por SM30 (pide confirmación)'.
  c_trkorr = 'Orden de customizing'.
  c_mode   = 'Modo batch input (N/E/A)'.
  c_all    = 'Mostrar también las cotizaciones que no cambian'.

AT SELECTION-SCREEN.
  IF p_mode <> 'N' AND p_mode <> 'E' AND p_mode <> 'A'.
    MESSAGE 'Modo batch input: N (sin pantallas), E (solo errores) o A (todas).' TYPE 'E'.
  ENDIF.

START-OF-SELECTION.
  CREATE OBJECT go_app.
  go_app->run( ).

*----------------------------------------------------------------------*
* Implementación
*----------------------------------------------------------------------*
CLASS lcl_app IMPLEMENTATION.

  METHOD run.
    DATA: lv_err TYPE string,
          lv_s1  TYPE string.

    lv_err = check_input( ).
    IF lv_err IS NOT INITIAL.
      MESSAGE lv_err TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    read_sap( ).
    build_plan( ).
    analyze( ).
    check_cuts( ).

    IF mv_block = abap_true.
      mv_result = 'Cambio BLOQUEADO: revisar las filas en rojo. No se modificó SAP.'.
    ELSEIF mv_n_new = 0.
      mv_result = 'Nada para crear: los factores ya existen con esos valores.'.
    ELSEIF p_real = abap_false.
      lv_s1 = fmt_int( mv_n_new ).
      CONCATENATE 'Simulación finalizada: no se modificó SAP. Se crearían'
                  lv_s1 'factor(es); ninguna cotización cambia de lectura.'
             INTO mv_result SEPARATED BY space.
    ELSEIF can_execute( ) = abap_true.
      execute( ).
    ENDIF.

    build_output( ).
    MESSAGE mv_result TYPE 'S'.
    display( ).
  ENDMETHOD.                    "run

*======================================================================*
* Validación de la pantalla: par existente y filas completas
*======================================================================*
  METHOD check_input.
    DATA: ls_new   TYPE ty_new,
          lt_new   TYPE ty_t_new,
          lv_waers TYPE tcurc-waers,
          lv_kurst TYPE tcurv-kurst,
          lv_n     TYPE i,
          lv_s1    TYPE string.
    FIELD-SYMBOLS <ls_new> TYPE ty_new.

    SELECT SINGLE kurst FROM tcurv INTO lv_kurst WHERE kurst = p_kurst.
    IF sy-subrc <> 0.
      CONCATENATE 'El tipo de cotización' p_kurst 'no existe (OB07).'
             INTO rv_error SEPARATED BY space.
      RETURN.
    ENDIF.
    SELECT SINGLE waers FROM tcurc INTO lv_waers WHERE waers = p_fcurr.
    IF sy-subrc <> 0.
      CONCATENATE 'La moneda' p_fcurr 'no existe en TCURC.' INTO rv_error SEPARATED BY space.
      RETURN.
    ENDIF.
    SELECT SINGLE waers FROM tcurc INTO lv_waers WHERE waers = p_tcurr.
    IF sy-subrc <> 0.
      CONCATENATE 'La moneda' p_tcurr 'no existe en TCURC.' INTO rv_error SEPARATED BY space.
      RETURN.
    ENDIF.
    IF p_fcurr = p_tcurr.
      rv_error = 'Moneda origen y destino iguales.'.
      RETURN.
    ENDIF.

*   Filas de factores: vacía = no se usa; incompleta = error
    DO 3 TIMES.
      CLEAR ls_new.
      ls_new-idx = sy-index.
      CASE sy-index.
        WHEN 1.
          ls_new-datum = p_d1. ls_new-ffact = p_ff1. ls_new-tfact = p_tf1.
        WHEN 2.
          ls_new-datum = p_d2. ls_new-ffact = p_ff2. ls_new-tfact = p_tf2.
        WHEN 3.
          ls_new-datum = p_d3. ls_new-ffact = p_ff3. ls_new-tfact = p_tf3.
      ENDCASE.
      IF ls_new-datum IS INITIAL AND ls_new-ffact IS INITIAL AND ls_new-tfact IS INITIAL.
        CONTINUE.
      ENDIF.
      lv_s1 = fmt_int( ls_new-idx ).
      IF ls_new-datum IS INITIAL OR ls_new-ffact <= 0 OR ls_new-tfact <= 0.
        CONCATENATE 'Factor' lv_s1 'incompleto: fecha y los dos factores (mayores que 0).'
               INTO rv_error SEPARATED BY space.
        RETURN.
      ENDIF.
      ls_new-status = gc_st_new.
      APPEND ls_new TO lt_new.
    ENDDO.
    IF lt_new IS INITIAL.
      rv_error = 'Indicar al menos un factor nuevo (fecha, factor de y factor a).'.
      RETURN.
    ENDIF.

*   Fechas repetidas en la pantalla
    SORT lt_new BY datum.
    LOOP AT lt_new ASSIGNING <ls_new>.
      lv_n = 0.
      LOOP AT lt_new TRANSPORTING NO FIELDS WHERE datum = <ls_new>-datum.
        lv_n = lv_n + 1.
      ENDLOOP.
      IF lv_n > 1.
        lv_s1 = fmt_date( <ls_new>-datum ).
        CONCATENATE 'Fecha repetida en los factores nuevos:' lv_s1
               INTO rv_error SEPARATED BY space.
        RETURN.
      ENDIF.
    ENDLOOP.
    mt_new = lt_new.
  ENDMETHOD.                    "check_input

*======================================================================*
* Lectura de TCURF (factores del par) y TCURR (cotizaciones del par)
*======================================================================*
  METHOD read_sap.
    DATA: lt_tcurf TYPE STANDARD TABLE OF tcurf,
          ls_tcurf TYPE tcurf,
          lt_tcurr TYPE STANDARD TABLE OF tcurr,
          ls_tcurr TYPE tcurr,
          ls_fac   TYPE ty_fac,
          ls_rate  TYPE ty_rate.

    SELECT * FROM tcurf INTO TABLE lt_tcurf
           WHERE kurst = p_kurst
             AND fcurr = p_fcurr
             AND tcurr = p_tcurr.
    LOOP AT lt_tcurf INTO ls_tcurf.
      CLEAR ls_fac.
      ls_fac-datum  = inv_to_date( ls_tcurf-gdatu ).
      ls_fac-ffact  = ls_tcurf-ffact.
      ls_fac-tfact  = ls_tcurf-tfact.
      ls_fac-origin = 'E'.
      APPEND ls_fac TO mt_cur.
    ENDLOOP.
    SORT mt_cur BY datum.

    SELECT * FROM tcurr INTO TABLE lt_tcurr
           WHERE kurst = p_kurst
             AND fcurr = p_fcurr
             AND tcurr = p_tcurr.
    LOOP AT lt_tcurr INTO ls_tcurr.
      CLEAR ls_rate.
      ls_rate-datum = inv_to_date( ls_tcurr-gdatu ).
      ls_rate-ukurs = ls_tcurr-ukurs.
      APPEND ls_rate TO mt_rates.
    ENDLOOP.
    SORT mt_rates BY datum.
  ENDMETHOD.                    "read_sap

*======================================================================*
* Plan = factores actuales + nuevos. Misma fecha que uno existente:
* iguales = ya existe; distintos = rechazado (no se modifica).
*======================================================================*
  METHOD build_plan.
    DATA: ls_cur TYPE ty_fac,
          ls_fac TYPE ty_fac,
          lv_txt TYPE string,
          lv_s1  TYPE string.
    FIELD-SYMBOLS <ls_new> TYPE ty_new.

    mt_plan = mt_cur.
    LOOP AT mt_new ASSIGNING <ls_new>.
      READ TABLE mt_cur INTO ls_cur WITH KEY datum = <ls_new>-datum.
      IF sy-subrc = 0.
        IF ls_cur-ffact = <ls_new>-ffact AND ls_cur-tfact = <ls_new>-tfact.
          <ls_new>-status = gc_st_same.
          <ls_new>-message = 'El factor ya existe con los mismos valores.'.
        ELSE.
          <ls_new>-status = gc_st_rej.
          lv_s1 = fmt_fac( iv_ffact = ls_cur-ffact iv_tfact = ls_cur-tfact ).
          CONCATENATE 'Ya existe un factor con esa fecha y otros valores ('
                      lv_s1 '). No se modifica: resolver a mano en OBBS.'
                 INTO lv_txt SEPARATED BY space.
          <ls_new>-message = lv_txt.
          mv_block = abap_true.
        ENDIF.
        CONTINUE.
      ENDIF.
      CLEAR ls_fac.
      ls_fac-datum  = <ls_new>-datum.
      ls_fac-ffact  = <ls_new>-ffact.
      ls_fac-tfact  = <ls_new>-tfact.
      ls_fac-origin = 'N'.
      APPEND ls_fac TO mt_plan.
      mv_n_new = mv_n_new + 1.
    ENDLOOP.
    SORT mt_plan BY datum.
  ENDMETHOD.                    "build_plan

*======================================================================*
* Cotizaciones existentes: ¿cambia el factor con que se leen?
*======================================================================*
  METHOD analyze.
    DATA: ls_rate TYPE ty_rate,
          lv_ff1  TYPE tcurf-ffact,
          lv_tf1  TYPE tcurf-tfact,
          lv_ok1  TYPE abap_bool,
          lv_ff2  TYPE tcurf-ffact,
          lv_tf2  TYPE tcurf-tfact,
          lv_ok2  TYPE abap_bool,
          ls_out  TYPE ty_out,
          lv_txt  TYPE string,
          lv_s1   TYPE string,
          lv_s2   TYPE string.

    LOOP AT mt_rates INTO ls_rate.
      factor_at( EXPORTING it_list = mt_cur  iv_date = ls_rate-datum
                 IMPORTING ev_ffact = lv_ff1 ev_tfact = lv_tf1 ev_found = lv_ok1 ).
      factor_at( EXPORTING it_list = mt_plan iv_date = ls_rate-datum
                 IMPORTING ev_ffact = lv_ff2 ev_tfact = lv_tf2 ev_found = lv_ok2 ).

      CLEAR ls_out.
      ls_out-fila   = 'COTIZACIÓN'.
      ls_out-fecha  = ls_rate-datum.
      ls_out-cotiz  = ls_rate-ukurs.
      ls_out-ff_act = lv_ff1.
      ls_out-tf_act = lv_tf1.
      ls_out-ff_new = lv_ff2.
      ls_out-tf_new = lv_tf2.
      ls_out-val_act = unit_value( iv_ukurs = ls_rate-ukurs iv_ffact = lv_ff1 iv_tfact = lv_tf1 ).
      ls_out-val_new = unit_value( iv_ukurs = ls_rate-ukurs iv_ffact = lv_ff2 iv_tfact = lv_tf2 ).

      IF lv_ff1 = lv_ff2 AND lv_tf1 = lv_tf2 AND lv_ok1 = lv_ok2.
        IF p_all = abap_true.
          ls_out-icon   = icon_light_out.
          ls_out-estado = 'SIN CAMBIO'.
          ls_out-mensaje = 'Se sigue leyendo con el mismo factor.'.
          APPEND ls_out TO mt_out.
        ENDIF.
        CONTINUE.
      ENDIF.

      mv_n_aff = mv_n_aff + 1.
      mv_block = abap_true.
      ls_out-icon   = icon_red_light.
      ls_out-estado = 'CAMBIA'.
      lv_s1 = fmt_fac( iv_ffact = lv_ff1 iv_tfact = lv_tf1 ).
      lv_s2 = fmt_fac( iv_ffact = lv_ff2 iv_tfact = lv_tf2 ).
      CONCATENATE 'Cambiaría de lectura: hoy' lv_s1 ', con el cambio' lv_s2
                  '. Bloquea: agregar un factor que mantenga el actual en esta fecha, o corregir la cotización.'
             INTO lv_txt SEPARATED BY space.
      ls_out-mensaje = lv_txt.
      APPEND ls_out TO mt_out.
    ENDLOOP.
  ENDMETHOD.                    "analyze

*======================================================================*
* Cortes: en cada fecha donde el factor efectivo cambia por el plan,
* tiene que haber una cotización de esa misma fecha, salvo que no haya
* ninguna cotización anterior (regla del incidente MXN).
*======================================================================*
  METHOD check_cuts.
    DATA: ls_fac    TYPE ty_fac,
          ls_prev   TYPE ty_fac,
          lv_has    TYPE abap_bool,
          lv_first  TYPE abap_bool,
          lv_before TYPE d,
          ls_rate   TYPE ty_rate,
          ls_out    TYPE ty_out,
          lv_txt    TYPE string,
          lv_s1     TYPE string,
          lv_s2     TYPE string.

*   Solo los cortes que toca el plan: cada factor nuevo y el factor
*   existente que viene justo después de uno nuevo (cambia su "antes").
    lv_first = abap_true.
    LOOP AT mt_plan INTO ls_fac.
      IF lv_first = abap_true.
        lv_first = abap_false.
        ls_prev = ls_fac.
        IF ls_fac-origin <> 'N'.
          CONTINUE.
        ENDIF.
*       Primer factor del par y es nuevo: no hay "antes"
        CLEAR ls_out.
        ls_out-icon   = icon_green_light.
        ls_out-fila   = 'CORTE'.
        ls_out-estado = 'OK'.
        ls_out-fecha  = ls_fac-datum.
        ls_out-ff_new = ls_fac-ffact.
        ls_out-tf_new = ls_fac-tfact.
        ls_out-mensaje = 'Primer factor del par: no hay factor anterior.'.
        APPEND ls_out TO mt_out.
        CONTINUE.
      ENDIF.

      IF ls_fac-origin <> 'N' AND ls_prev-origin <> 'N'.
        ls_prev = ls_fac.
        CONTINUE.
      ENDIF.

*     ¿Cambia el factor efectivo en esta fecha?
      IF ls_fac-ffact = ls_prev-ffact AND ls_fac-tfact = ls_prev-tfact.
        CLEAR ls_out.
        ls_out-icon   = icon_green_light.
        ls_out-fila   = 'CORTE'.
        ls_out-estado = 'OK'.
        ls_out-fecha  = ls_fac-datum.
        ls_out-ff_act = ls_prev-ffact.
        ls_out-tf_act = ls_prev-tfact.
        ls_out-ff_new = ls_fac-ffact.
        ls_out-tf_new = ls_fac-tfact.
        ls_out-mensaje = 'El factor no cambia en esta fecha: sin efecto sobre las conversiones.'.
        APPEND ls_out TO mt_out.
        ls_prev = ls_fac.
        CONTINUE.
      ENDIF.

*     Cotización en la misma fecha y cotizaciones anteriores
      lv_has = abap_false.
      CLEAR lv_before.
      LOOP AT mt_rates INTO ls_rate.
        IF ls_rate-datum = ls_fac-datum.
          lv_has = abap_true.
        ELSEIF ls_rate-datum < ls_fac-datum.
          lv_before = ls_rate-datum.          " queda la última anterior
        ENDIF.
      ENDLOOP.

      CLEAR ls_out.
      ls_out-fila   = 'CORTE'.
      ls_out-fecha  = ls_fac-datum.
      ls_out-ff_act = ls_prev-ffact.
      ls_out-tf_act = ls_prev-tfact.
      ls_out-ff_new = ls_fac-ffact.
      ls_out-tf_new = ls_fac-tfact.
      IF lv_has = abap_true.
        ls_out-icon   = icon_green_light.
        ls_out-estado = 'OK'.
        ls_out-mensaje = 'Hay cotización de esta misma fecha: las conversiones desde acá usan una cotización cargada con el factor nuevo.'.
      ELSEIF lv_before IS INITIAL.
        ls_out-icon   = icon_green_light.
        ls_out-estado = 'OK'.
        ls_out-mensaje = 'No hay cotizaciones anteriores: ninguna conversión mezcla factores.'.
      ELSE.
        ls_out-icon   = icon_red_light.
        ls_out-estado = 'BLOQUEA'.
        mv_block = abap_true.
        mv_n_cut = mv_n_cut + 1.
        lv_s1 = fmt_date( lv_before ).
        lv_s2 = fmt_fac( iv_ffact = ls_prev-ffact iv_tfact = ls_prev-tfact ).
        CONCATENATE 'Sin cotización de esta fecha: las conversiones desde acá usarían la del'
                    lv_s1 ', cargada con' lv_s2
                    ', con el factor nuevo. Cargar primero una cotización de esta fecha.'
               INTO lv_txt SEPARATED BY space.
        ls_out-mensaje = lv_txt.
      ENDIF.
      APPEND ls_out TO mt_out.
      ls_prev = ls_fac.
    ENDLOOP.
  ENDMETHOD.                    "check_cuts

*----------------------------------------------------------------------*
* Factor vigente a una fecha: el de fecha más reciente <= iv_date
*----------------------------------------------------------------------*
  METHOD factor_at.
    DATA ls_fac TYPE ty_fac.

    CLEAR: ev_ffact, ev_tfact.
    ev_found = abap_false.
    LOOP AT it_list INTO ls_fac WHERE datum <= iv_date.
      ev_ffact = ls_fac-ffact.
      ev_tfact = ls_fac-tfact.
      ev_found = abap_true.
    ENDLOOP.
  ENDMETHOD.                    "factor_at

*----------------------------------------------------------------------*
* Valor de 1 unidad de origen en moneda destino (solo notación directa)
*----------------------------------------------------------------------*
  METHOD unit_value.
    CLEAR rv_value.
    IF iv_ukurs <= 0 OR iv_ffact IS INITIAL.
      RETURN.
    ENDIF.
    TRY.
        rv_value = iv_ukurs * iv_tfact / iv_ffact.
      CATCH cx_sy_arithmetic_error.
        CLEAR rv_value.
    ENDTRY.
  ENDMETHOD.                    "unit_value

*======================================================================*
* Orden de transporte: debe existir, ser de customizing y modificable
*======================================================================*
  METHOD check_request.
    DATA ls_e070 TYPE e070.

    CLEAR rv_error.
    IF p_trkorr IS INITIAL.
      rv_error = 'Indicar la orden de customizing para la ejecución real.'.
      RETURN.
    ENDIF.
    SELECT SINGLE * FROM e070 INTO ls_e070 WHERE trkorr = p_trkorr.
    IF sy-subrc <> 0.
      CONCATENATE 'La orden' p_trkorr 'no existe.' INTO rv_error SEPARATED BY space.
      RETURN.
    ENDIF.
    IF ls_e070-strkorr IS NOT INITIAL.
      CONCATENATE p_trkorr 'es una tarea; indicar la orden superior' ls_e070-strkorr
             INTO rv_error SEPARATED BY space.
      RETURN.
    ENDIF.
    IF ls_e070-trfunction <> 'W'.
      CONCATENATE 'La orden' p_trkorr 'no es de customizing (tipo W).'
             INTO rv_error SEPARATED BY space.
      RETURN.
    ENDIF.
    IF ls_e070-trstatus <> 'D'.
      CONCATENATE 'La orden' p_trkorr 'no está modificable (liberada o bloqueada).'
             INTO rv_error SEPARATED BY space.
    ENDIF.
  ENDMETHOD.                    "check_request

  METHOD can_execute.
    DATA: lv_err TYPE string,
          lv_txt TYPE string,
          lv_s1  TYPE string,
          lv_q   TYPE c LENGTH 400,
          lv_ans TYPE c LENGTH 1.

    rv_ok = abap_false.
    IF sy-batch = abap_true.
      mv_result = 'La ejecución real en fondo no está habilitada.'.
      RETURN.
    ENDIF.
    lv_err = check_request( ).
    IF lv_err IS NOT INITIAL.
      CONCATENATE 'Ejecución cancelada:' lv_err INTO mv_result SEPARATED BY space.
      RETURN.
    ENDIF.

    lv_s1 = fmt_int( mv_n_new ).
    CONCATENATE 'Se crearán por SM30' lv_s1 'factor(es)' p_kurst p_fcurr '->' p_tcurr
                'en la orden' p_trkorr '. Ninguna cotización cambia de lectura. ¿Continuar?'
           INTO lv_txt SEPARATED BY space.
    lv_q = lv_txt.
    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = 'SAP FX Free - Factores'
        text_question         = lv_q
        text_button_1         = 'Crear'
        text_button_2         = 'Cancelar'
        default_button        = '2'
        display_cancel_button = space
      IMPORTING
        answer                = lv_ans
      EXCEPTIONS
        text_not_found        = 1
        OTHERS                = 2.
    IF sy-subrc <> 0 OR lv_ans <> '1'.
      mv_result = 'Ejecución cancelada por el usuario.'.
      RETURN.
    ENDIF.
    rv_ok = abap_true.
  ENDMETHOD.                    "can_execute

*======================================================================*
* Ejecución: fecha descendente (el factor más nuevo primero), corte en
* el primer error. SM30 confirma cada alta por separado.
*======================================================================*
  METHOD execute.
    DATA: lv_stop TYPE abap_bool,
          lv_txt  TYPE string,
          lv_s1   TYPE string.
    FIELD-SYMBOLS <ls_new> TYPE ty_new.

    SORT mt_new BY datum DESCENDING.
    LOOP AT mt_new ASSIGNING <ls_new> WHERE status = gc_st_new.
      IF lv_stop = abap_true.
        <ls_new>-status = gc_st_skip.
        add_msg( EXPORTING iv_text = 'No procesado: la ejecución se detuvo por un error anterior.'
                 CHANGING  cv_msg  = <ls_new>-message ).
        CONTINUE.
      ENDIF.
      create_factor( CHANGING cs_new = <ls_new> ).
      IF <ls_new>-status = gc_st_fail.
        lv_stop = abap_true.
      ELSE.
        mv_n_done = mv_n_done + 1.
      ENDIF.
    ENDLOOP.
    SORT mt_new BY datum.

    lv_s1 = fmt_int( mv_n_done ).
    IF lv_stop = abap_true.
      CONCATENATE 'Ejecución detenida por un error de batch input. Factores creados:'
                  lv_s1 '(quedan en la orden' p_trkorr
                  '). Revisar OBBS antes de convertir con este par.'
             INTO lv_txt SEPARATED BY space.
    ELSE.
      CONCATENATE 'Ejecución finalizada:' lv_s1
                  'factor(es) creados y verificados en la orden' p_trkorr '.'
             INTO lv_txt SEPARATED BY space.
    ENDIF.
    mv_result = lv_txt.
  ENDMETHOD.                    "execute

*----------------------------------------------------------------------*
* Alta de factor por SM30 / V_TCURF (misma secuencia que ZFX_FREE_SETUP,
* grabada en SHDB el 24.10.2026)
*----------------------------------------------------------------------*
  METHOD create_factor.
    DATA: lv_text  TYPE string,
          lv_date  TYPE c LENGTH 10,
          lv_ff    TYPE c LENGTH 12,
          lv_tf    TYPE c LENGTH 12,
          lv_inv   TYPE tcurf-gdatu,
          ls_tcurf TYPE tcurf.

    WRITE cs_new-datum TO lv_date.                " formato del usuario
    WRITE cs_new-ffact TO lv_ff LEFT-JUSTIFIED NO-GROUPING DECIMALS 0.
    WRITE cs_new-tfact TO lv_tf LEFT-JUSTIFIED NO-GROUPING DECIMALS 0.

    CLEAR mt_bdc.
    bdc_dynpro( iv_program = 'SAPMSVMA' iv_dynpro = '0100' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=UPD' ).
    bdc_field( iv_fnam = 'VIEWNAME'                iv_fval = 'V_TCURF' ).
    bdc_field( iv_fnam = 'VIMDYNFLDS-LTD_DTA_NO'   iv_fval = 'X' ).
*   Aviso estándar de OBBS ("Making changes to the table of translation
*   factors...") -> Sí
    bdc_dynpro( iv_program = 'SAPLSPO1' iv_dynpro = '0600' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=OPT1' ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0120' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=NEWL' ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0120' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '/00' ).
    bdc_field( iv_fnam = 'V_TCURF-KURST(01)'       iv_fval = p_kurst ).
    bdc_field( iv_fnam = 'V_TCURF-FCURR(01)'       iv_fval = p_fcurr ).
    bdc_field( iv_fnam = 'V_TCURF-TCURR(01)'       iv_fval = p_tcurr ).
    bdc_field( iv_fnam = 'V_TCURF-GDATU(01)'       iv_fval = lv_date ).
    bdc_field( iv_fnam = 'V_TCURF-FFACT(01)'       iv_fval = lv_ff ).
    bdc_field( iv_fnam = 'V_TCURF-TFACT(01)'       iv_fval = lv_tf ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0120' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=SAVE' ).
    bdc_dynpro( iv_program = 'SAPLSTRD' iv_dynpro = '0300' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=LOCK' ).
    bdc_field( iv_fnam = 'KO008-TRKORR'            iv_fval = p_trkorr ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0120' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=BACK' ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0120' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=BACK' ).
    bdc_dynpro( iv_program = 'SAPMSVMA' iv_dynpro = '0100' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '/EBACK' ).

    call_sm30( IMPORTING ev_text = lv_text ).

*   Verificación: la entrada tiene que existir con los factores pedidos
    lv_inv = date_to_inv( cs_new-datum ).
    SELECT SINGLE * FROM tcurf INTO ls_tcurf
           WHERE kurst = p_kurst
             AND fcurr = p_fcurr
             AND tcurr = p_tcurr
             AND gdatu = lv_inv.
    IF sy-subrc = 0 AND ls_tcurf-ffact = cs_new-ffact AND ls_tcurf-tfact = cs_new-tfact.
      cs_new-status = gc_st_done.
      add_msg( EXPORTING iv_text = 'Factor creado y verificado en TCURF.'
               CHANGING  cv_msg  = cs_new-message ).
    ELSE.
      cs_new-status = gc_st_fail.
      CONCATENATE 'No se creó el factor (SM30):' lv_text INTO lv_text SEPARATED BY space.
      add_msg( EXPORTING iv_text = lv_text CHANGING cv_msg = cs_new-message ).
    ENDIF.
  ENDMETHOD.                    "create_factor

  METHOD call_sm30.
    DATA: lt_msg TYPE STANDARD TABLE OF bdcmsgcoll,
          ls_msg TYPE bdcmsgcoll,
          ls_opt TYPE ctu_params,
          lv_rc  TYPE i,
          lv_txt TYPE string,
          lv_s1  TYPE string.

    CLEAR ev_text.
    ls_opt-dismode  = p_mode.
    ls_opt-updmode  = 'S'.
    ls_opt-defsize  = 'X'.
    ls_opt-racommit = 'X'.

    CALL TRANSACTION 'SM30' USING mt_bdc
         OPTIONS FROM ls_opt
         MESSAGES INTO lt_msg.
    lv_rc = sy-subrc.

    lv_s1 = fmt_int( lv_rc ).
    CONCATENATE 'CALL TRANSACTION sy-subrc =' lv_s1
           INTO ev_text SEPARATED BY space.
    IF lt_msg IS INITIAL.
      add_msg( EXPORTING iv_text = 'sin mensajes del batch input (repetir en modo E para ver la pantalla)'
               CHANGING  cv_msg  = ev_text ).
    ENDIF.
    LOOP AT lt_msg INTO ls_msg.
      MESSAGE ID ls_msg-msgid TYPE 'I' NUMBER ls_msg-msgnr
              WITH ls_msg-msgv1 ls_msg-msgv2 ls_msg-msgv3 ls_msg-msgv4
              INTO lv_txt.
      CONCATENATE ls_msg-msgtyp ls_msg-msgid ls_msg-msgnr lv_txt
                  '[' ls_msg-dyname ls_msg-dynumb ']'
             INTO lv_txt SEPARATED BY space.
      add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = ev_text ).
    ENDLOOP.
  ENDMETHOD.                    "call_sm30

  METHOD bdc_dynpro.
    DATA ls_bdc TYPE bdcdata.
    ls_bdc-program  = iv_program.
    ls_bdc-dynpro   = iv_dynpro.
    ls_bdc-dynbegin = 'X'.
    APPEND ls_bdc TO mt_bdc.
  ENDMETHOD.                    "bdc_dynpro

  METHOD bdc_field.
    DATA ls_bdc TYPE bdcdata.
    ls_bdc-fnam = iv_fnam.
    ls_bdc-fval = iv_fval.
    APPEND ls_bdc TO mt_bdc.
  ENDMETHOD.                    "bdc_field

*======================================================================*
* Log: resumen, factores actuales, factores nuevos, cortes y
* cotizaciones (las de cortes y cotizaciones ya están en mt_out)
*======================================================================*
  METHOD add_out.
    DATA ls_out TYPE ty_out.
    ls_out-icon    = iv_icon.
    ls_out-fila    = iv_fila.
    ls_out-estado  = iv_estado.
    ls_out-mensaje = iv_text.
    APPEND ls_out TO mt_out.
  ENDMETHOD.                    "add_out

  METHOD build_output.
    DATA: lt_detail TYPE ty_t_out,
          ls_out    TYPE ty_out,
          ls_fac    TYPE ty_fac,
          ls_new    TYPE ty_new,
          ls_rate   TYPE ty_rate,
          lv_txt    TYPE string,
          lv_s1     TYPE string,
          lv_s2     TYPE string,
          lv_s3     TYPE string,
          lv_n      TYPE i.

    lt_detail = mt_out.                   " cortes y cotizaciones
    CLEAR mt_out.

*   ---- Resumen ------------------------------------------------------
    CONCATENATE 'Par:' p_kurst p_fcurr '->' p_tcurr INTO lv_txt SEPARATED BY space.
    add_out( iv_icon = icon_information iv_fila = 'RESUMEN' iv_estado = '' iv_text = lv_txt ).
    IF p_real = abap_true.
      CONCATENATE 'Modo: EJECUCIÓN REAL - orden' p_trkorr INTO lv_txt SEPARATED BY space.
    ELSE.
      lv_txt = 'Modo: SIMULACIÓN (no se modificó SAP)'.
    ENDIF.
    add_out( iv_icon = icon_information iv_fila = 'RESUMEN' iv_estado = '' iv_text = lv_txt ).

    lv_n = lines( mt_rates ).
    lv_s1 = fmt_int( lv_n ).
    IF mt_rates IS NOT INITIAL.
      READ TABLE mt_rates INTO ls_rate INDEX 1.
      lv_s2 = fmt_date( ls_rate-datum ).
      READ TABLE mt_rates INTO ls_rate INDEX lv_n.
      lv_s3 = fmt_date( ls_rate-datum ).
      CONCATENATE 'Cotizaciones del par en TCURR:' lv_s1 '(del' lv_s2 'al'
                  lv_s3 ')'
             INTO lv_txt SEPARATED BY space.
    ELSE.
      lv_txt = 'Cotizaciones del par en TCURR: ninguna.'.
    ENDIF.
    add_out( iv_icon = icon_information iv_fila = 'RESUMEN' iv_estado = '' iv_text = lv_txt ).

    lv_s1 = fmt_int( mv_n_new ).
    lv_s2 = fmt_int( mv_n_aff ).
    lv_s3 = fmt_int( mv_n_cut ).
    CONCATENATE 'Factores para crear:' lv_s1
                '| Cotizaciones que cambian de lectura:' lv_s2
                '| Cortes sin cotización:' lv_s3
           INTO lv_txt SEPARATED BY space.
    add_out( iv_icon = icon_information iv_fila = 'RESUMEN' iv_estado = '' iv_text = lv_txt ).
    CONCATENATE 'Resultado:' mv_result INTO lv_txt SEPARATED BY space.
    add_out( iv_icon = icon_information iv_fila = 'RESUMEN' iv_estado = '' iv_text = lv_txt ).

*   ---- Factores actuales (OBBS) -------------------------------------
    LOOP AT mt_cur INTO ls_fac.
      CLEAR ls_out.
      ls_out-icon    = icon_light_out.
      ls_out-fila    = 'FACTOR ACTUAL'.
      ls_out-estado  = 'EXISTE'.
      ls_out-fecha   = ls_fac-datum.
      ls_out-ff_act  = ls_fac-ffact.
      ls_out-tf_act  = ls_fac-tfact.
      ls_out-mensaje = 'Factor vigente en OBBS desde esta fecha.'.
      APPEND ls_out TO mt_out.
    ENDLOOP.
    IF mt_cur IS INITIAL.
      add_out( iv_icon = icon_light_out iv_fila = 'FACTOR ACTUAL' iv_estado = ''
               iv_text = 'El par no tiene factores en OBBS.' ).
    ENDIF.

*   ---- Factores nuevos ----------------------------------------------
    LOOP AT mt_new INTO ls_new.
      CLEAR ls_out.
      ls_out-fila   = 'FACTOR NUEVO'.
      ls_out-fecha  = ls_new-datum.
      ls_out-ff_new = ls_new-ffact.
      ls_out-tf_new = ls_new-tfact.
      CASE ls_new-status.
        WHEN gc_st_new.
          IF mv_block = abap_true.
            ls_out-icon   = icon_yellow_light.
            ls_out-estado = 'NO SE CREA'.
            ls_out-mensaje = 'El cambio está bloqueado (ver filas en rojo).'.
          ELSE.
            ls_out-icon   = icon_green_light.
            ls_out-estado = 'PARA CREAR'.
            ls_out-mensaje = ls_new-message.
          ENDIF.
        WHEN gc_st_same.
          ls_out-icon   = icon_light_out.
          ls_out-estado = 'YA EXISTE'.
          ls_out-mensaje = ls_new-message.
        WHEN gc_st_rej.
          ls_out-icon   = icon_red_light.
          ls_out-estado = 'RECHAZADO'.
          ls_out-mensaje = ls_new-message.
        WHEN gc_st_done.
          ls_out-icon   = icon_okay.
          ls_out-estado = 'CREADO'.
          ls_out-mensaje = ls_new-message.
        WHEN gc_st_fail.
          ls_out-icon   = icon_cancel.
          ls_out-estado = 'ERROR'.
          ls_out-mensaje = ls_new-message.
        WHEN gc_st_skip.
          ls_out-icon   = icon_cancel.
          ls_out-estado = 'NO PROCESADO'.
          ls_out-mensaje = ls_new-message.
      ENDCASE.
      APPEND ls_out TO mt_out.
    ENDLOOP.

*   ---- Cortes y cotizaciones (del análisis) -------------------------
    APPEND LINES OF lt_detail TO mt_out.
  ENDMETHOD.                    "build_output

  METHOD display.
    DATA: lo_alv   TYPE REF TO cl_salv_table,
          lo_func  TYPE REF TO cl_salv_functions_list,
          lo_cols  TYPE REF TO cl_salv_columns_table,
          lo_colt  TYPE REF TO cl_salv_column_table,
          lo_disp  TYPE REF TO cl_salv_display_settings,
          lx_msg   TYPE REF TO cx_salv_msg,
          lv_title TYPE lvc_title,
          lv_txt   TYPE string.

    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = lo_alv
                                CHANGING  t_table      = mt_out ).
      CATCH cx_salv_msg INTO lx_msg.
        lv_txt = lx_msg->get_text( ).
        MESSAGE lv_txt TYPE 'S' DISPLAY LIKE 'E'.
        RETURN.
    ENDTRY.

    lo_func = lo_alv->get_functions( ).
    lo_func->set_all( abap_true ).
    lo_cols = lo_alv->get_columns( ).
    lo_cols->set_optimize( abap_true ).

    set_col( io_cols = lo_cols iv_name = 'ICON'    iv_long = 'Semáforo'
             iv_med = 'Semáforo'       iv_short = 'Sem.' ).
    set_col( io_cols = lo_cols iv_name = 'FILA'    iv_long = 'Tipo de fila'
             iv_med = 'Fila'           iv_short = 'Fila' ).
    set_col( io_cols = lo_cols iv_name = 'ESTADO'  iv_long = 'Estado'
             iv_med = 'Estado'         iv_short = 'Estado' ).
    set_col( io_cols = lo_cols iv_name = 'FECHA'   iv_long = 'Fecha'
             iv_med = 'Fecha'          iv_short = 'Fecha' ).
    set_col( io_cols = lo_cols iv_name = 'FF_ACT'  iv_long = 'Factor de (actual)'
             iv_med = 'Fact.de actual' iv_short = 'FdeAct' ).
    set_col( io_cols = lo_cols iv_name = 'TF_ACT'  iv_long = 'Factor a (actual)'
             iv_med = 'Fact.a actual'  iv_short = 'FaAct' ).
    set_col( io_cols = lo_cols iv_name = 'FF_NEW'  iv_long = 'Factor de (con el cambio)'
             iv_med = 'Fact.de nuevo'  iv_short = 'FdeNue' ).
    set_col( io_cols = lo_cols iv_name = 'TF_NEW'  iv_long = 'Factor a (con el cambio)'
             iv_med = 'Fact.a nuevo'   iv_short = 'FaNue' ).
    set_col( io_cols = lo_cols iv_name = 'COTIZ'   iv_long = 'Cotización en TCURR'
             iv_med = 'Cotización'     iv_short = 'Cotiz.' ).
    set_col( io_cols = lo_cols iv_name = 'VAL_ACT' iv_long = 'Valor de 1 unidad (actual)'
             iv_med = '1 unidad actual' iv_short = 'ValAct' ).
    set_col( io_cols = lo_cols iv_name = 'VAL_NEW' iv_long = 'Valor de 1 unidad (con el cambio)'
             iv_med = '1 unidad nuevo' iv_short = 'ValNue' ).
    set_col( io_cols = lo_cols iv_name = 'MENSAJE' iv_long = 'Mensaje'
             iv_med = 'Mensaje'        iv_short = 'Mensaje' ).

    TRY.
        lo_colt ?= lo_cols->get_column( 'ICON' ).
        lo_colt->set_icon( if_salv_c_bool_sap=>true ).
      CATCH cx_salv_not_found.
    ENDTRY.

    lo_disp = lo_alv->get_display_settings( ).
    lo_disp->set_striped_pattern( abap_true ).
    IF p_real = abap_true.
      lv_title = 'SAP FX Free - Factores - EJECUCIÓN REAL'.
    ELSE.
      lv_title = 'SAP FX Free - Factores - SIMULACIÓN'.
    ENDIF.
    lo_disp->set_list_header( lv_title ).
    lo_alv->display( ).
  ENDMETHOD.                    "display

*----------------------------------------------------------------------*
* Utilidades
*----------------------------------------------------------------------*
  METHOD inv_to_date.
    DATA lv_c TYPE c LENGTH 8.
    lv_c = iv_inv.
    TRANSLATE lv_c USING gc_inv.
    rv_date = lv_c.
  ENDMETHOD.                    "inv_to_date

  METHOD date_to_inv.
    DATA lv_c TYPE c LENGTH 8.
    lv_c = iv_date.
    TRANSLATE lv_c USING gc_inv.
    rv_inv = lv_c.
  ENDMETHOD.                    "date_to_inv

  METHOD fmt_int.
    DATA lv_c TYPE c LENGTH 12.
    WRITE iv_int TO lv_c LEFT-JUSTIFIED NO-GROUPING.
    rv_text = lv_c.
  ENDMETHOD.                    "fmt_int

  METHOD fmt_date.
    DATA lv_c TYPE c LENGTH 10.
    WRITE iv_date TO lv_c DD/MM/YYYY.
    rv_text = lv_c.
  ENDMETHOD.                    "fmt_date

  METHOD fmt_fac.
    DATA: lv_f TYPE c LENGTH 12,
          lv_t TYPE c LENGTH 12.
    IF iv_ffact IS INITIAL AND iv_tfact IS INITIAL.
      rv_text = 'sin factor'.
      RETURN.
    ENDIF.
    WRITE iv_ffact TO lv_f LEFT-JUSTIFIED DECIMALS 0.
    WRITE iv_tfact TO lv_t LEFT-JUSTIFIED DECIMALS 0.
    CONCATENATE lv_f ':' lv_t INTO rv_text.
  ENDMETHOD.                    "fmt_fac

  METHOD add_msg.
    IF iv_text IS INITIAL.
      RETURN.
    ENDIF.
    IF cv_msg IS INITIAL.
      cv_msg = iv_text.
    ELSE.
      CONCATENATE cv_msg iv_text INTO cv_msg SEPARATED BY ` | `.
    ENDIF.
  ENDMETHOD.                    "add_msg

  METHOD set_col.
    DATA lo_col TYPE REF TO cl_salv_column.
    TRY.
        lo_col = io_cols->get_column( iv_name ).
        lo_col->set_long_text( iv_long ).
        lo_col->set_medium_text( iv_med ).
        lo_col->set_short_text( iv_short ).
      CATCH cx_salv_not_found.
    ENDTRY.
  ENDMETHOD.                    "set_col
ENDCLASS.                    "lcl_app IMPLEMENTATION
