*&---------------------------------------------------------------------*
*& Report ZFX_FREE_LOAD
*&---------------------------------------------------------------------*
*& SAP FX Free - Carga de cotizaciones tipo M (destino ARS) desde el
*& CSV generado por el script Python (fuente BCRA).
*&
*& Reglas de diseño:
*&  - Solo interfaces estándar del objeto de negocio ExchangeRate
*&    (grupo BUS1093). Nunca se escribe en TCURR/TCURF/TCURV.
*&  - Modo SIMULACIÓN por defecto: solo lee el archivo y consulta SAP.
*&  - Modo CARGA REAL solo con opción explícita + confirmación.
*&  - Se valida TODO el archivo antes de cualquier actualización.
*&  - Una única LUW: se cargan todas las cotizaciones aceptadas o
*&    ninguna (BAPI_EXCHRATE_CREATEMULTIPLE + COMMIT/ROLLBACK).
*&  - No se sobrescriben cotizaciones existentes (UPD_ALLOW vacío).
*&
*& Compatibilidad: SAP_BASIS 731. Sin declaraciones inline, sin
*& expresiones constructoras, sin NEW, sin string templates ni &&.
*&
*& Versión 1.2 - 24.10.2026 (lista blanca = tabla mt_exp; EUR omitido)
*& Versión 1.3 - 24.10.2026 (lista blanca = factores M X->ARS de OBBS;
*&               aviso cerca del máximo de EXCH_RATE)
*&---------------------------------------------------------------------*
REPORT zfx_free_load.

TYPE-POOLS: abap, icon.

*----------------------------------------------------------------------*
* Tipos globales
*----------------------------------------------------------------------*
TYPES: ty_t_string TYPE STANDARD TABLE OF string WITH DEFAULT KEY.

* Registro CSV crudo (campos ya separados y sin comillas)
TYPES: BEGIN OF ty_record,
         line   TYPE i,                  " línea física donde empieza
         fields TYPE ty_t_string,
       END OF ty_record,
       ty_t_record TYPE STANDARD TABLE OF ty_record WITH DEFAULT KEY.

* Registro de trabajo (una cotización del archivo)
TYPES: BEGIN OF ty_item,
         line         TYPE i,
         status       TYPE c LENGTH 1,   " ver constantes gc_st_*
         warning      TYPE abap_bool,
         currency     TYPE string,
         description  TYPE string,
         rate_type    TYPE bapi1093_0-rate_type,
         from_curr    TYPE bapi1093_0-from_curr,
         to_currncy   TYPE bapi1093_0-to_currncy,
         valid_from   TYPE d,
         rate_text    TYPE string,                 " valor tal cual vino
         rate_src     TYPE p LENGTH 16 DECIMALS 9, " ARS por 1 unidad
         from_factor  TYPE bapi1093_0-from_factor,
         to_factor    TYPE bapi1093_0-to_factor,
         rate_sap     TYPE bapi1093_0-exch_rate,   " DEC 9,5
         prev_rate    TYPE bapi1093_0-exch_rate,
         prev_date    TYPE d,
         variation    TYPE p LENGTH 8 DECIMALS 2,
         source       TYPE string,
         source_url   TYPE string,
         source_date  TYPE string,
         source_field TYPE string,
         csv_status   TYPE string,
         message      TYPE string,
       END OF ty_item,
       ty_t_item TYPE STANDARD TABLE OF ty_item WITH DEFAULT KEY.

* Línea del log (ALV)
TYPES: BEGIN OF ty_out,
         icon        TYPE icon_d,
         estado      TYPE c LENGTH 15,
         linea       TYPE i,
         moneda      TYPE waers,
         a_moneda    TYPE waers,
         tipo        TYPE kurst_curr,
         fecha       TYPE d,
         tasa_origen TYPE c LENGTH 25,
         tasa_sap    TYPE ukursp,
         factor_de   TYPE ffact_curr,
         factor_a    TYPE tfact_curr,
         tasa_vig    TYPE ukursp,
         fecha_vig   TYPE d,
         variacion   TYPE c LENGTH 12,
         fuente      TYPE c LENGTH 20,
         fecha_fte   TYPE c LENGTH 10,
         estado_csv  TYPE c LENGTH 20,
         mensaje     TYPE c LENGTH 255,
         url         TYPE c LENGTH 255,
       END OF ty_out,
       ty_t_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

*----------------------------------------------------------------------*
* Constantes
*----------------------------------------------------------------------*
CONSTANTS:
  gc_rate_type TYPE bapi1093_0-rate_type  VALUE 'M',
  gc_to_curr   TYPE bapi1093_0-to_currncy VALUE 'ARS',
* Máximo representable en EXCH_RATE (UKURSP = DEC 9,5)
  gc_max_rate  TYPE p LENGTH 16 DECIMALS 9 VALUE '9999.99999',
* A partir de este valor se advierte: conviene prever factor ARS 10
  gc_warn_rate TYPE p LENGTH 16 DECIMALS 9 VALUE '8000',
  gc_max_bytes TYPE i VALUE 1048576,      " 1 MB: el CSV real pesa < 5 KB
  gc_min_date  TYPE d VALUE '19900101',
* Estados internos
  gc_st_acc    TYPE c LENGTH 1 VALUE 'A',  " aceptado (listo para cargar)
  gc_st_rej    TYPE c LENGTH 1 VALUE 'R',  " rechazado (bloquea la carga)
  gc_st_omi    TYPE c LENGTH 1 VALUE 'O',  " omitido (par derivado de otro tipo)
  gc_st_load   TYPE c LENGTH 1 VALUE 'L',  " cargado y verificado
  gc_st_notl   TYPE c LENGTH 1 VALUE 'N',  " no cargado (revertido)
  gc_st_chk    TYPE c LENGTH 1 VALUE 'V'.  " commit OK, verificación no coincide

*----------------------------------------------------------------------*
* Pantalla de selección
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b01 WITH FRAME TITLE t_b01.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_file FOR FIELD p_file.
PARAMETERS p_file TYPE rlgrap-filename LOWER CASE OBLIGATORY
                  VISIBLE LENGTH 45.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_stat FOR FIELD p_stat.
PARAMETERS p_stat(20) TYPE c DEFAULT 'REVIEW_REQUIRED'.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b01.

SELECTION-SCREEN BEGIN OF BLOCK b02 WITH FRAME TITLE t_b02.
SELECTION-SCREEN BEGIN OF LINE.
PARAMETERS p_sim RADIOBUTTON GROUP mod DEFAULT 'X'.
SELECTION-SCREEN COMMENT 4(70) c_sim FOR FIELD p_sim.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
PARAMETERS p_real RADIOBUTTON GROUP mod.
SELECTION-SCREEN COMMENT 4(70) c_real FOR FIELD p_real.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b02.

SELECTION-SCREEN BEGIN OF BLOCK b03 WITH FRAME TITLE t_b03.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_desv FOR FIELD p_desv.
PARAMETERS p_desv TYPE i DEFAULT 10.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
PARAMETERS p_acept AS CHECKBOX.
SELECTION-SCREEN COMMENT 4(70) c_acept FOR FIELD p_acept.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b03.

*----------------------------------------------------------------------*
* Clase principal
*----------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS f4_file CHANGING cv_file TYPE rlgrap-filename.
    METHODS constructor.
    METHODS run.

  PRIVATE SECTION.
    TYPES: BEGIN OF ty_col,
             name TYPE string,
             idx  TYPE i,
           END OF ty_col,
           ty_t_col TYPE HASHED TABLE OF ty_col WITH UNIQUE KEY name.

    DATA: mt_items    TYPE ty_t_item,
          mt_out      TYPE ty_t_out,
          mt_cols     TYPE ty_t_col,
          mt_req      TYPE ty_t_string,
          mt_bapi_msg TYPE ty_t_string,
          mv_ncols    TYPE i,
          mv_result   TYPE string,
          mv_n_total  TYPE i,
          mv_n_acc    TYPE i,
          mv_n_warn   TYPE i,
          mv_n_rej    TYPE i,
          mv_n_omi    TYPE i,
          mv_n_load   TYPE i,
          mv_n_notl   TYPE i.

    METHODS read_file
      IMPORTING iv_file    TYPE rlgrap-filename
      EXPORTING ev_content TYPE string
                ev_error   TYPE string.
    METHODS parse_csv
      IMPORTING iv_content TYPE string
      EXPORTING et_records TYPE ty_t_record
                ev_error   TYPE string.
    METHODS map_header
      IMPORTING is_header TYPE ty_record
      EXPORTING ev_error  TYPE string.
    METHODS get_value
      IMPORTING is_rec          TYPE ty_record
                iv_name         TYPE string
      RETURNING value(rv_value) TYPE string.
    METHODS check_record
      IMPORTING is_rec         TYPE ty_record
      RETURNING value(rs_item) TYPE ty_item.
    METHODS check_duplicates.
    METHODS check_sap.
    METHODS check_auth
      RETURNING value(rv_ok) TYPE abap_bool.
    METHODS can_load
      RETURNING value(rv_ok) TYPE abap_bool.
    METHODS load.
    METHODS verify_loaded.
    METHODS count_status.
    METHODS build_output.
    METHODS display.

    CLASS-METHODS add_msg
      IMPORTING iv_text TYPE string
      CHANGING  cv_msg  TYPE string.
    CLASS-METHODS msg_text1
      IMPORTING is_ret         TYPE bapiret1
      RETURNING value(rv_text) TYPE string.
    CLASS-METHODS msg_text2
      IMPORTING is_ret         TYPE bapiret2
      RETURNING value(rv_text) TYPE string.
    CLASS-METHODS fmt_num
      IMPORTING iv_val         TYPE p
                iv_dec         TYPE i
      RETURNING value(rv_text) TYPE string.
    CLASS-METHODS fmt_int
      IMPORTING iv_int         TYPE i
      RETURNING value(rv_text) TYPE string.
    CLASS-METHODS fmt_date
      IMPORTING iv_date        TYPE d
      RETURNING value(rv_text) TYPE string.
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
  t_b01   = 'Archivo CSV (script Python SAP FX Free)'.
  t_b02   = 'Modo de ejecución'.
  t_b03   = 'Controles'.
  c_file  = 'Archivo CSV local'.
  c_stat  = 'Estado esperado en el CSV'.
  c_sim   = 'Simulación: valida y muestra el log, no modifica SAP'.
  c_real  = 'Carga real: crea las cotizaciones (pide confirmación)'.
  c_desv  = 'Variación para advertir (%)'.
  c_acept = 'Acepto las advertencias revisadas (solo carga real)'.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  lcl_app=>f4_file( CHANGING cv_file = p_file ).

AT SELECTION-SCREEN.
  IF p_desv <= 0 OR p_desv > 1000.
    MESSAGE 'El umbral de variación debe estar entre 1 y 1000 %.' TYPE 'E'.
  ENDIF.

START-OF-SELECTION.
  CREATE OBJECT go_app.
  go_app->run( ).

*----------------------------------------------------------------------*
* Implementación
*----------------------------------------------------------------------*
CLASS lcl_app IMPLEMENTATION.

*======================================================================*
* Constructor: contrato del CSV
*======================================================================*
  METHOD constructor.
*   Columnas obligatorias (contrato real del script Python)
    APPEND 'currency'      TO mt_req.
    APPEND 'description'   TO mt_req.
    APPEND 'rate_type'     TO mt_req.
    APPEND 'from_currency' TO mt_req.
    APPEND 'to_currency'   TO mt_req.
    APPEND 'valid_from'    TO mt_req.
    APPEND 'rate'          TO mt_req.
    APPEND 'source'        TO mt_req.
    APPEND 'source_url'    TO mt_req.
    APPEND 'source_date'   TO mt_req.
    APPEND 'source_field'  TO mt_req.
    APPEND 'status'        TO mt_req.
*   v1.3: ya no hay lista blanca fija. Un par se admite solo si tiene
*   una entrada explícita M X->ARS en OBBS (TCURF) vigente a la fecha;
*   ver check_sap. Las altas se hacen con ZFX_FREE_SETUP.
  ENDMETHOD.                    "constructor

*======================================================================*
* F4: diálogo de selección de archivo de SAP GUI
*======================================================================*
  METHOD f4_file.
    DATA: lt_files  TYPE filetable,
          ls_file   TYPE file_table,
          lv_rc     TYPE i,
          lv_action TYPE i.

    cl_gui_frontend_services=>file_open_dialog(
      EXPORTING
        window_title            = 'Seleccionar CSV de cotizaciones'
        default_extension       = 'csv'
        file_filter             = 'CSV (*.csv)|*.csv|Todos (*.*)|*.*'
      CHANGING
        file_table              = lt_files
        rc                      = lv_rc
        user_action             = lv_action
      EXCEPTIONS
        file_open_dialog_failed = 1
        cntl_error              = 2
        OTHERS                  = 3 ).
    IF sy-subrc <> 0.
      MESSAGE 'No se pudo abrir el diálogo de archivos de SAP GUI.'
        TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.
    IF lv_action = cl_gui_frontend_services=>action_ok AND lv_rc >= 1.
      READ TABLE lt_files INTO ls_file INDEX 1.
      IF sy-subrc = 0.
        cv_file = ls_file-filename.
      ENDIF.
    ENDIF.
  ENDMETHOD.                    "f4_file

*======================================================================*
* Proceso principal
*======================================================================*
  METHOD run.
    DATA: lv_content TYPE string,
          lv_error   TYPE string,
          lt_records TYPE ty_t_record,
          ls_record  TYPE ty_record,
          ls_item    TYPE ty_item,
          lv_n       TYPE i,
          lv_s1      TYPE string.

    IF sy-batch = abap_true.
      MESSAGE 'Ejecutar en diálogo: el archivo se lee desde SAP GUI.'
        TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

*   1) Lectura binaria + conversión UTF-8 (con BOM)
    read_file( EXPORTING iv_file    = p_file
               IMPORTING ev_content = lv_content
                         ev_error   = lv_error ).
    IF lv_error IS NOT INITIAL.
      MESSAGE lv_error TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

*   2) Parser CSV (RFC 4180: comillas, comillas dobles, comas)
    parse_csv( EXPORTING iv_content = lv_content
               IMPORTING et_records = lt_records
                         ev_error   = lv_error ).
    IF lv_error IS NOT INITIAL.
      MESSAGE lv_error TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.
    lv_n = lines( lt_records ).
    IF lv_n < 2.
      MESSAGE 'El archivo no tiene cabecera y al menos una cotización.'
        TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

*   3) Cabecera
    READ TABLE lt_records INTO ls_record INDEX 1.
    map_header( EXPORTING is_header = ls_record
                IMPORTING ev_error  = lv_error ).
    IF lv_error IS NOT INITIAL.
      MESSAGE lv_error TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

*   4) Validación de contenido línea por línea (sin consultar SAP)
    LOOP AT lt_records INTO ls_record FROM 2.
      ls_item = check_record( ls_record ).
      APPEND ls_item TO mt_items.
    ENDLOOP.

*   5) Duplicados dentro del archivo
    check_duplicates( ).

*   6) Validaciones contra SAP (solo lectura): factores, conversión,
*      cotización existente para la misma fecha, variación.
    check_sap( ).
    count_status( ).

*   7) Carga real (solo si todo el archivo es consistente)
    IF p_real = abap_true.
      IF can_load( ) = abap_true.
        load( ).
        count_status( ).
      ENDIF.
    ELSE.
      lv_s1 = fmt_int( mv_n_acc ).
      CONCATENATE 'Simulación finalizada: no se modificó SAP.'
                  lv_s1
                  'cotización(es) quedarían listas para cargar.'
             INTO mv_result SEPARATED BY space.
    ENDIF.

*   8) Log
    build_output( ).
    MESSAGE mv_result TYPE 'S'.
    display( ).
  ENDMETHOD.                    "run

*======================================================================*
* Lectura del archivo: binario -> xstring -> quitar BOM -> UTF-8
* Se lee en binario para no depender del codepage del frontend y
* poder detectar y quitar el BOM (EF BB BF) de forma explícita.
*======================================================================*
  METHOD read_file.
    DATA: lt_bin   TYPE solix_tab,
          lv_len   TYPE i,
          lv_xlen  TYPE i,
          lv_xstr  TYPE xstring,
          lv_fname TYPE string,
          lo_conv  TYPE REF TO cl_abap_conv_in_ce,
          lx_root  TYPE REF TO cx_root,
          lv_bom   TYPE x LENGTH 3 VALUE 'EFBBBF',
          lv_head  TYPE x LENGTH 3.

    CLEAR: ev_content, ev_error.
    lv_fname = iv_file.

    cl_gui_frontend_services=>gui_upload(
      EXPORTING
        filename        = lv_fname
        filetype        = 'BIN'
      IMPORTING
        filelength      = lv_len
      CHANGING
        data_tab        = lt_bin
      EXCEPTIONS
        file_open_error = 1
        file_read_error = 2
        OTHERS          = 3 ).
    IF sy-subrc <> 0.
      CONCATENATE 'No se pudo leer el archivo' lv_fname
                  '(verificar ruta y permisos de SAP GUI).'
             INTO ev_error SEPARATED BY space.
      RETURN.
    ENDIF.
    IF lv_len <= 0.
      ev_error = 'El archivo está vacío.'.
      RETURN.
    ENDIF.
    IF lv_len > gc_max_bytes.
      ev_error = 'El archivo supera 1 MB; no parece un CSV de cotizaciones.'.
      RETURN.
    ENDIF.

    CALL FUNCTION 'SCMS_BINARY_TO_XSTRING'
      EXPORTING
        input_length = lv_len
      IMPORTING
        buffer       = lv_xstr
      TABLES
        binary_tab   = lt_bin
      EXCEPTIONS
        failed       = 1
        OTHERS       = 2.
    IF sy-subrc <> 0.
      ev_error = 'Error al convertir el archivo a XSTRING.'.
      RETURN.
    ENDIF.

*   Quitar BOM UTF-8 si está presente
    lv_xlen = xstrlen( lv_xstr ).
    IF lv_xlen >= 3.
      lv_head = lv_xstr(3).
      IF lv_head = lv_bom.
        lv_xstr = lv_xstr+3.
      ENDIF.
    ENDIF.

*   UTF-8 (codepage SAP 4110) -> STRING. Un byte inválido corta la
*   lectura (ignore_cerr = false): mejor rechazar que cargar basura.
    TRY.
        lo_conv = cl_abap_conv_in_ce=>create( encoding    = '4110'
                                              ignore_cerr = abap_false
                                              input       = lv_xstr ).
        lo_conv->read( IMPORTING data = ev_content ).
      CATCH cx_root INTO lx_root.
        ev_error = lx_root->get_text( ).
        CONCATENATE 'El archivo no es UTF-8 válido:' ev_error
               INTO ev_error SEPARATED BY space.
        CLEAR ev_content.
    ENDTRY.
  ENDMETHOD.                    "read_file

*======================================================================*
* Parser CSV (RFC 4180) por recorrido de caracteres.
* - Delimitador coma; campos opcionalmente entre comillas dobles.
* - Dentro de comillas: "" = comilla literal; se admiten comas y
*   saltos de línea.
* - Fin de registro: CRLF, LF o CR.
* - Líneas vacías se ignoran.
* No usa SPLIT AT ',' para no romper campos entrecomillados.
*======================================================================*
  METHOD parse_csv.
    DATA: lv_len     TYPE i,
          lv_pos     TYPE i,
          lv_pos1    TYPE i,
          lv_flen    TYPE i,
          lv_start   TYPE i,
          lv_line    TYPE i,
          lv_c       TYPE c LENGTH 1,
          lv_next    TYPE c LENGTH 1,
          lv_crlf    TYPE c LENGTH 2,
          lv_cr      TYPE c LENGTH 1,
          lv_lf      TYPE c LENGTH 1,
          lv_in_q    TYPE abap_bool,
          lv_after_q TYPE abap_bool,
          lv_data    TYPE abap_bool,
          lv_field   TYPE string,
          lv_qfield  TYPE string,
          lv_s1      TYPE string,
          ls_rec     TYPE ty_record.

    CLEAR: et_records, ev_error.
    lv_crlf = cl_abap_char_utilities=>cr_lf.
    lv_cr   = lv_crlf+0(1).
    lv_lf   = lv_crlf+1(1).
    lv_len  = strlen( iv_content ).
    lv_line = 1.
    ls_rec-line = 1.

    WHILE lv_pos < lv_len.
      lv_c = iv_content+lv_pos(1).

*     ---- Dentro de un campo entrecomillado --------------------------
      IF lv_in_q = abap_true.
        IF lv_c = '"'.
          lv_pos1 = lv_pos + 1.
          CLEAR lv_next.
          IF lv_pos1 < lv_len.
            lv_next = iv_content+lv_pos1(1).
          ENDIF.
          IF lv_next = '"'.
*           Comilla escapada ("") -> se resuelve al cerrar el campo
            lv_pos = lv_pos + 2.
            CONTINUE.
          ENDIF.
*         Comilla de cierre
          lv_flen = lv_pos - lv_start.
          CLEAR lv_qfield.
          IF lv_flen > 0.
            lv_qfield = iv_content+lv_start(lv_flen).
          ENDIF.
          REPLACE ALL OCCURRENCES OF '""' IN lv_qfield WITH '"'.
          lv_in_q    = abap_false.
          lv_after_q = abap_true.
        ELSEIF lv_c = lv_lf.
          lv_line = lv_line + 1.
        ENDIF.
        lv_pos = lv_pos + 1.
        CONTINUE.
      ENDIF.

*     ---- Fuera de comillas ------------------------------------------
      IF lv_c = '"'.
        IF lv_pos = lv_start AND lv_after_q = abap_false.
          lv_in_q  = abap_true.
          lv_data  = abap_true.
          lv_start = lv_pos + 1.
        ELSE.
          lv_s1 = fmt_int( lv_line ).
          CONCATENATE 'CSV inválido: comilla inesperada en la línea'
                      lv_s1 '.'
                 INTO ev_error SEPARATED BY space.
          RETURN.
        ENDIF.

      ELSEIF lv_c = ','.
*       Fin de campo
        lv_data = abap_true.
        IF lv_after_q = abap_true.
          lv_field = lv_qfield.
        ELSE.
          lv_flen = lv_pos - lv_start.
          CLEAR lv_field.
          IF lv_flen > 0.
            lv_field = iv_content+lv_start(lv_flen).
          ENDIF.
        ENDIF.
        APPEND lv_field TO ls_rec-fields.
        lv_after_q = abap_false.
        lv_start   = lv_pos + 1.

      ELSEIF lv_c = lv_cr OR lv_c = lv_lf.
*       Fin de registro
        IF lv_after_q = abap_true.
          lv_field = lv_qfield.
        ELSE.
          lv_flen = lv_pos - lv_start.
          CLEAR lv_field.
          IF lv_flen > 0.
            lv_field = iv_content+lv_start(lv_flen).
          ENDIF.
        ENDIF.
        IF lv_data = abap_true OR lv_field IS NOT INITIAL.
          APPEND lv_field TO ls_rec-fields.
          APPEND ls_rec TO et_records.
        ENDIF.
        CLEAR: ls_rec, lv_data, lv_after_q.
*       CRLF cuenta como un solo salto
        IF lv_c = lv_cr.
          lv_pos1 = lv_pos + 1.
          CLEAR lv_next.
          IF lv_pos1 < lv_len.
            lv_next = iv_content+lv_pos1(1).
          ENDIF.
          IF lv_next = lv_lf.
            lv_pos = lv_pos1.
          ENDIF.
        ENDIF.
        lv_line     = lv_line + 1.
        ls_rec-line = lv_line.
        lv_start    = lv_pos + 1.

      ELSE.
        IF lv_after_q = abap_true.
          lv_s1 = fmt_int( lv_line ).
          CONCATENATE 'CSV inválido: texto después de una comilla de'
                      'cierre en la línea' lv_s1 '.'
                 INTO ev_error SEPARATED BY space.
          RETURN.
        ENDIF.
        lv_data = abap_true.
      ENDIF.

      lv_pos = lv_pos + 1.
    ENDWHILE.

    IF lv_in_q = abap_true.
      lv_s1 = fmt_int( ls_rec-line ).
      CONCATENATE 'CSV inválido: comillas sin cerrar en el registro que'
                  'empieza en la línea' lv_s1 '.'
             INTO ev_error SEPARATED BY space.
      RETURN.
    ENDIF.

*   Último registro sin salto de línea final
    IF lv_after_q = abap_true.
      lv_field = lv_qfield.
    ELSE.
      lv_flen = lv_len - lv_start.
      CLEAR lv_field.
      IF lv_flen > 0.
        lv_field = iv_content+lv_start(lv_flen).
      ENDIF.
    ENDIF.
    IF lv_data = abap_true OR lv_field IS NOT INITIAL.
      APPEND lv_field TO ls_rec-fields.
      APPEND ls_rec TO et_records.
    ENDIF.
  ENDMETHOD.                    "parse_csv

*======================================================================*
* Cabecera: mapa nombre de columna -> posición
*======================================================================*
  METHOD map_header.
    DATA: lv_name TYPE string,
          lv_req  TYPE string,
          ls_col  TYPE ty_col.

    CLEAR: mt_cols, ev_error.
    LOOP AT is_header-fields INTO lv_name.
      ls_col-idx = sy-tabix.
      CONDENSE lv_name.
      TRANSLATE lv_name TO LOWER CASE.
      ls_col-name = lv_name.
      INSERT ls_col INTO TABLE mt_cols.
      IF sy-subrc <> 0.
        CONCATENATE 'Cabecera inválida: columna repetida' lv_name
               INTO ev_error SEPARATED BY space.
        RETURN.
      ENDIF.
    ENDLOOP.

    LOOP AT mt_req INTO lv_req.
      READ TABLE mt_cols TRANSPORTING NO FIELDS
           WITH TABLE KEY name = lv_req.
      IF sy-subrc <> 0.
        CONCATENATE 'Cabecera inválida: falta la columna obligatoria'
                    lv_req
               INTO ev_error SEPARATED BY space.
        RETURN.
      ENDIF.
    ENDLOOP.

    mv_ncols = lines( is_header-fields ).
  ENDMETHOD.                    "map_header

  METHOD get_value.
    DATA ls_col TYPE ty_col.
    CLEAR rv_value.
    READ TABLE mt_cols INTO ls_col WITH TABLE KEY name = iv_name.
    IF sy-subrc = 0.
      READ TABLE is_rec-fields INTO rv_value INDEX ls_col-idx.
    ENDIF.
  ENDMETHOD.                    "get_value

*======================================================================*
* Validación de contenido de una línea (no consulta SAP)
*======================================================================*
  METHOD check_record.
    DATA: lv_rtype TYPE string,
          lv_from  TYPE string,
          lv_to    TYPE string,
          lv_date  TYPE string,
          lv_exp   TYPE string,
          lv_txt   TYPE string,
          lv_s1    TYPE string,
          lv_s2    TYPE string,
          lv_dc    TYPE c LENGTH 8,
          lv_d2    TYPE d,
          lv_days  TYPE i,
          lv_n     TYPE i,
          lv_bad   TYPE abap_bool.

    rs_item-line   = is_rec-line.
    rs_item-status = gc_st_rej.          " se libera al final

*   Cantidad de columnas
    lv_n = lines( is_rec-fields ).
    IF lv_n <> mv_ncols.
      lv_s1 = fmt_int( lv_n ).
      lv_s2 = fmt_int( mv_ncols ).
      CONCATENATE 'La línea tiene' lv_s1
                  'columnas; la cabecera tiene' lv_s2 '.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.

*   Lectura de campos
    rs_item-currency     = get_value( is_rec = is_rec iv_name = 'currency' ).
    rs_item-description  = get_value( is_rec = is_rec iv_name = 'description' ).
    lv_rtype             = get_value( is_rec = is_rec iv_name = 'rate_type' ).
    lv_from              = get_value( is_rec = is_rec iv_name = 'from_currency' ).
    lv_to                = get_value( is_rec = is_rec iv_name = 'to_currency' ).
    lv_date              = get_value( is_rec = is_rec iv_name = 'valid_from' ).
    rs_item-rate_text    = get_value( is_rec = is_rec iv_name = 'rate' ).
    rs_item-source       = get_value( is_rec = is_rec iv_name = 'source' ).
    rs_item-source_url   = get_value( is_rec = is_rec iv_name = 'source_url' ).
    rs_item-source_date  = get_value( is_rec = is_rec iv_name = 'source_date' ).
    rs_item-source_field = get_value( is_rec = is_rec iv_name = 'source_field' ).
    rs_item-csv_status   = get_value( is_rec = is_rec iv_name = 'status' ).

    CONDENSE: rs_item-currency, rs_item-description, lv_rtype, lv_from,
              lv_to, lv_date, rs_item-rate_text, rs_item-source,
              rs_item-source_url, rs_item-source_date,
              rs_item-source_field, rs_item-csv_status.
    TRANSLATE: rs_item-currency TO UPPER CASE, lv_rtype TO UPPER CASE,
               lv_from TO UPPER CASE, lv_to TO UPPER CASE,
               rs_item-csv_status TO UPPER CASE.

*   Tipo de cotización
    IF lv_rtype <> 'M'.
      CONCATENATE 'Tipo de cotización' lv_rtype
                  'no admitido: solo se acepta M.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    rs_item-rate_type = gc_rate_type.

*   Moneda destino
    IF lv_to <> 'ARS'.
      CONCATENATE 'Moneda destino' lv_to 'no admitida: solo ARS.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    rs_item-to_currncy = gc_to_curr.

*   Coherencia currency / from_currency
    IF rs_item-currency <> lv_from.
      CONCATENATE 'Las columnas currency (' rs_item-currency
                  ') y from_currency (' lv_from ') no coinciden.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.

*   Moneda origen: código SAP de hasta 5 caracteres. Si el par está
*   habilitado se decide en check_sap (factores explícitos en OBBS).
    lv_n = strlen( lv_from ).
    IF lv_n < 3 OR lv_n > 5.
      CONCATENATE 'Código de moneda' lv_from 'inválido (3 a 5 caracteres).'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    rs_item-from_curr = lv_from.

*   Estado del registro según el contrato del script Python
    lv_exp = p_stat.
    CONDENSE lv_exp.
    TRANSLATE lv_exp TO UPPER CASE.
    IF rs_item-csv_status <> lv_exp.
      CONCATENATE 'Estado CSV' rs_item-csv_status 'inesperado: se esperaba'
                  lv_exp '.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.

*   Fuente
    IF rs_item-source IS INITIAL.
      rs_item-message = 'La columna source está vacía.'.
      RETURN.
    ENDIF.

*   Fecha valid_from (AAAA-MM-DD, válida, no futura)
    FIND REGEX '^\d{4}-\d{2}-\d{2}$' IN lv_date.
    IF sy-subrc <> 0.
      CONCATENATE 'Fecha valid_from' lv_date
                  'con formato inválido: se espera AAAA-MM-DD.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    CONCATENATE lv_date+0(4) lv_date+5(2) lv_date+8(2) INTO lv_dc.
    rs_item-valid_from = lv_dc.
*   Una fecha inexistente (p. ej. 2026-02-30) se convierte a 0 días
    lv_days = rs_item-valid_from.
    lv_d2   = lv_days.
    IF lv_days = 0 OR lv_d2 <> rs_item-valid_from.
      CONCATENATE 'Fecha valid_from' lv_date 'inexistente en el calendario.'
             INTO rs_item-message SEPARATED BY space.
      CLEAR rs_item-valid_from.
      RETURN.
    ENDIF.
    IF rs_item-valid_from > sy-datlo.
      CONCATENATE 'Fecha valid_from' lv_date 'es futura.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    IF rs_item-valid_from < gc_min_date.
      CONCATENATE 'Fecha valid_from' lv_date 'anterior a 1990: no se carga.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    IF rs_item-source_date <> lv_date.
      CONCATENATE 'source_date (' rs_item-source_date
                  ') distinta de valid_from (' lv_date ').'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.

*   Cotización: solo dígitos y punto decimal, sin miles ni exponente
    FIND REGEX '^\d{1,9}(\.\d{1,9})?$' IN rs_item-rate_text.
    IF sy-subrc <> 0.
      CONCATENATE 'Cotización' rs_item-rate_text
                  'no numérica o con formato inválido (usar punto decimal, sin separador de miles, máx. 9 decimales).'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    lv_bad = abap_false.
    TRY.
        rs_item-rate_src = rs_item-rate_text.
      CATCH cx_sy_conversion_no_number cx_sy_conversion_overflow.
        lv_bad = abap_true.
    ENDTRY.
    IF lv_bad = abap_true.
      CONCATENATE 'Cotización' rs_item-rate_text 'no convertible a número.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    IF rs_item-rate_src <= 0.
      CONCATENATE 'Cotización' rs_item-rate_text 'debe ser mayor que cero.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.

*   Todo correcto a nivel de contenido
    rs_item-status = gc_st_acc.
    CONCATENATE 'Fuente' rs_item-source rs_item-source_date
           INTO lv_txt SEPARATED BY space.
    add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = rs_item-message ).
  ENDMETHOD.                    "check_record

*======================================================================*
* Duplicados: mismo par y fecha más de una vez -> se rechazan todos
*======================================================================*
  METHOD check_duplicates.
    DATA: lt_copy  TYPE ty_t_item,
          ls_other TYPE ty_item,
          lv_n     TYPE i,
          lv_lines TYPE string,
          lv_s1    TYPE string,
          lv_txt   TYPE string.
    FIELD-SYMBOLS <ls_item> TYPE ty_item.

    lt_copy = mt_items.
    LOOP AT mt_items ASSIGNING <ls_item> WHERE status = gc_st_acc.
      CLEAR: lv_n, lv_lines.
      LOOP AT lt_copy INTO ls_other
           WHERE status     = gc_st_acc
             AND from_curr  = <ls_item>-from_curr
             AND valid_from = <ls_item>-valid_from.
        lv_n = lv_n + 1.
        lv_s1 = fmt_int( ls_other-line ).
        IF lv_lines IS INITIAL.
          lv_lines = lv_s1.
        ELSE.
          CONCATENATE lv_lines lv_s1 INTO lv_lines SEPARATED BY `, `.
        ENDIF.
      ENDLOOP.
      IF lv_n > 1.
        <ls_item>-status = gc_st_rej.
        CONCATENATE 'Duplicado en el archivo: el par y la fecha se repiten en las líneas'
                    lv_lines
               INTO lv_txt SEPARATED BY space.
        <ls_item>-message = lv_txt.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.                    "check_duplicates

*======================================================================*
* Validaciones contra SAP (solo lectura)
*======================================================================*
  METHOD check_sap.
    DATA: lv_rtype TYPE bapi1093_1-rate_type,
          lv_fcurr TYPE bapi1093_1-from_curr,
          lv_tcurr TYPE bapi1093_1-to_currncy,
          lv_date  TYPE bapi1093_2-trans_date,
          lv_ffact TYPE bapi1093_0-from_factor,
          lv_tfact TYPE bapi1093_0-to_factor,
          ls_ret1  TYPE bapiret1,
          ls_exch  TYPE bapi1093_0,
          lt_tcurf TYPE STANDARD TABLE OF tcurf,
          ls_tcurf TYPE tcurf,
          lv_invd  TYPE tcurf-gdatu,
          lv_calc  TYPE p LENGTH 16 DECIMALS 9,
          lv_round TYPE p LENGTH 16 DECIMALS 5,
          lv_absv  TYPE p LENGTH 8 DECIMALS 2,
          lv_fail  TYPE abap_bool,
          lv_txt   TYPE string,
          lv_s1    TYPE string,
          lv_s2    TYPE string,
          lv_s3    TYPE string,
          lv_s4    TYPE string,
          lv_bmsg  TYPE string.
    FIELD-SYMBOLS <ls_item> TYPE ty_item.

    LOOP AT mt_items ASSIGNING <ls_item> WHERE status = gc_st_acc.
      lv_rtype = <ls_item>-rate_type.
      lv_fcurr = <ls_item>-from_curr.
      lv_tcurr = <ls_item>-to_currncy.
      lv_date  = <ls_item>-valid_from.

*     ---- 0) Par habilitado: entrada explícita en OBBS (TCURF) -------
*     Sin entrada, SAP asume 1:1 en silencio; por eso se exige una
*     entrada vigente a la fecha (la más reciente con fecha <= valid_from).
*     TCURF-GDATU guarda la fecha invertida (99999999 - AAAAMMDD): fecha
*     <= valid_from equivale a GDATU >= invertida(valid_from).
      lv_invd = <ls_item>-valid_from.
      TRANSLATE lv_invd USING '09182736455463728190'.
      CLEAR: lt_tcurf, ls_tcurf.
      SELECT * FROM tcurf INTO TABLE lt_tcurf UP TO 1 ROWS
             WHERE kurst = lv_rtype
               AND fcurr = lv_fcurr
               AND tcurr = lv_tcurr
               AND gdatu >= lv_invd
             ORDER BY gdatu ASCENDING.
      READ TABLE lt_tcurf INTO ls_tcurf INDEX 1.
      IF sy-subrc <> 0.
        CONCATENATE 'El par M' <ls_item>-from_curr
                    '->ARS no tiene factores en OBBS vigentes a la fecha: darlo de alta con ZFX_FREE_SETUP.'
               INTO <ls_item>-message SEPARATED BY space.
        <ls_item>-status = gc_st_rej.
        CONTINUE.
      ENDIF.
*     Par derivado de otro tipo de cotización (p. ej. M EUR -> EURX):
*     la cotización M no se carga; se deriva del tipo alternativo.
      IF ls_tcurf-abwct IS NOT INITIAL.
        CONCATENATE 'Omitido: M' <ls_item>-from_curr '->ARS deriva del tipo'
                    ls_tcurf-abwct 'en OBBS; no se carga como tipo M.'
               INTO <ls_item>-message SEPARATED BY space.
        <ls_item>-status = gc_st_omi.
        CONTINUE.
      ENDIF.

*     ---- 1) Factores vigentes en SAP para tipo/par/fecha -----------
      CLEAR: lv_ffact, lv_tfact, ls_ret1.
      CALL FUNCTION 'BAPI_EXCHANGERATE_GETFACTORS'
        EXPORTING
          rate_type   = lv_rtype
          from_curr   = lv_fcurr
          to_currncy  = lv_tcurr
          date        = lv_date
        IMPORTING
          from_factor = lv_ffact
          to_factor   = lv_tfact
          return      = ls_ret1.
      IF ls_ret1-type CA 'EAX'.
        lv_bmsg = msg_text1( ls_ret1 ).
        CONCATENATE 'No se pudieron leer los factores en SAP:' lv_bmsg
               INTO <ls_item>-message SEPARATED BY space.
        <ls_item>-status = gc_st_rej.
        CONTINUE.
      ENDIF.
      <ls_item>-from_factor = lv_ffact.
      <ls_item>-to_factor   = lv_tfact.
      IF lv_ffact <= 0 OR lv_tfact <= 0.
        <ls_item>-message = 'SAP devolvió factores vacíos para el par: no se puede convertir la cotización.'.
        <ls_item>-status  = gc_st_rej.
        CONTINUE.
      ENDIF.

*     Control cruzado: la BAPI tiene que devolver los mismos factores
*     que la entrada de OBBS leída (el programa nunca ajusta factores).
      IF ls_tcurf-ffact <> lv_ffact OR ls_tcurf-tfact <> lv_tfact.
        lv_s1 = fmt_num( iv_val = lv_ffact       iv_dec = 0 ).
        lv_s2 = fmt_num( iv_val = lv_tfact       iv_dec = 0 ).
        lv_s3 = fmt_num( iv_val = ls_tcurf-ffact iv_dec = 0 ).
        lv_s4 = fmt_num( iv_val = ls_tcurf-tfact iv_dec = 0 ).
        CONCATENATE 'Factores de la BAPI' lv_s1 ':' lv_s2
                    'distintos de OBBS' lv_s3 ':' lv_s4
                    '. Revisar OBBS antes de cargar.'
               INTO <ls_item>-message SEPARATED BY space.
        <ls_item>-status = gc_st_rej.
        CONTINUE.
      ENDIF.

*     ---- 2) Conversión: BCRA da ARS por 1 unidad de origen ---------
*     SAP espera ARS por FROM_FACTOR unidades / TO_FACTOR.
      lv_fail = abap_false.
      TRY.
          lv_calc  = <ls_item>-rate_src * lv_ffact / lv_tfact.
          lv_round = lv_calc.             " redondeo comercial a 5 dec.
        CATCH cx_sy_arithmetic_error.
          lv_fail = abap_true.
      ENDTRY.
      IF lv_fail = abap_true.
        <ls_item>-message = 'Error aritmético al convertir la cotización.'.
        <ls_item>-status  = gc_st_rej.
        CONTINUE.
      ENDIF.
      IF lv_round <= 0.
        <ls_item>-message = 'La cotización convertida queda en 0 con 5 decimales.'.
        <ls_item>-status  = gc_st_rej.
        CONTINUE.
      ENDIF.
      IF lv_round > gc_max_rate.
        lv_s1 = fmt_num( iv_val = lv_round iv_dec = 5 ).
        CONCATENATE 'La cotización convertida' lv_s1
                    'supera el máximo de EXCH_RATE (9999,99999). Dar de alta en OBBS un factor ARS 10 (p. ej. 1:10) con nueva fecha.'
               INTO <ls_item>-message SEPARATED BY space.
        <ls_item>-status = gc_st_rej.
        CONTINUE.
      ENDIF.
      <ls_item>-rate_sap = lv_round.
      IF lv_round >= gc_warn_rate.
        <ls_item>-warning = abap_true.
        lv_s1 = fmt_num( iv_val = lv_round iv_dec = 5 ).
        CONCATENATE 'ADVERTENCIA: cotización' lv_s1
                    'cerca del máximo de SAP (9999,99999). Prever factor ARS 10 en OBBS.'
               INTO lv_txt SEPARATED BY space.
        add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = <ls_item>-message ).
      ENDIF.
      IF lv_round <> lv_calc.
        lv_s1 = fmt_num( iv_val = lv_calc iv_dec = 9 ).
        CONCATENATE 'Redondeada a 5 decimales (valor exacto'
                    lv_s1 ')'
               INTO lv_txt SEPARATED BY space.
        add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = <ls_item>-message ).
      ENDIF.

*     ---- 3) Cotización vigente/existente en SAP --------------------
      CLEAR: ls_exch, ls_ret1.
      CALL FUNCTION 'BAPI_EXCHANGERATE_GETDETAIL'
        EXPORTING
          rate_type  = lv_rtype
          from_curr  = lv_fcurr
          to_currncy = lv_tcurr
          date       = lv_date
        IMPORTING
          exch_rate  = ls_exch
          return     = ls_ret1.

      IF ls_exch-exch_rate IS INITIAL AND ls_exch-exch_rate_v IS INITIAL.
*       No hay cotización vigente a esa fecha. La BAPI de creación
*       igual rechaza (E020) si apareciera una para la misma fecha.
        lv_txt = 'Sin cotización vigente en SAP a esa fecha'.
        lv_bmsg = msg_text1( ls_ret1 ).
        IF lv_bmsg IS NOT INITIAL.
          CONCATENATE lv_txt '(GETDETAIL:' lv_bmsg ')'
                 INTO lv_txt SEPARATED BY space.
        ENDIF.
        add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = <ls_item>-message ).
        CONTINUE.
      ENDIF.

      <ls_item>-prev_date = ls_exch-valid_from.
      <ls_item>-prev_rate = ls_exch-exch_rate.

      IF ls_exch-valid_from IS INITIAL OR ls_exch-valid_from > <ls_item>-valid_from.
        <ls_item>-message = 'GETDETAIL devolvió una cotización sin fecha coherente: no se puede descartar una sobrescritura. Revisar en OB08.'.
        <ls_item>-status  = gc_st_rej.
        CONTINUE.
      ENDIF.

      IF ls_exch-valid_from = <ls_item>-valid_from.
        lv_s1 = fmt_date( ls_exch-valid_from ).
        lv_s2 = fmt_num( iv_val = ls_exch-exch_rate iv_dec = 5 ).
        CONCATENATE 'Ya existe la cotización M' <ls_item>-from_curr
                    '->ARS del' lv_s1 '(valor' lv_s2
                    '). No se sobrescribe: resolver manualmente en OB08.'
               INTO <ls_item>-message SEPARATED BY space.
        <ls_item>-status = gc_st_rej.
        CONTINUE.
      ENDIF.

*     Cotización anterior: informar y medir la variación
      IF ls_exch-exch_rate IS INITIAL.
        <ls_item>-warning = abap_true.
        lv_txt = 'La cotización vigente está en notación indirecta: comparar manualmente.'.
        add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = <ls_item>-message ).
        CONTINUE.
      ENDIF.
      IF ls_exch-from_factor IS NOT INITIAL
         AND ( ls_exch-from_factor <> lv_ffact OR ls_exch-to_factor <> lv_tfact ).
        <ls_item>-warning = abap_true.
        lv_txt = 'La cotización vigente usa otros factores: variación no comparable.'.
        add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = <ls_item>-message ).
        CONTINUE.
      ENDIF.

      lv_fail = abap_false.
      TRY.
          <ls_item>-variation = ( <ls_item>-rate_sap - ls_exch-exch_rate )
                                * 100 / ls_exch-exch_rate.
        CATCH cx_sy_arithmetic_error.
          lv_fail = abap_true.
      ENDTRY.
      IF lv_fail = abap_true.
        <ls_item>-warning = abap_true.
        lv_txt = 'Variación contra la cotización vigente fuera de rango.'.
        add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = <ls_item>-message ).
        CONTINUE.
      ENDIF.

      lv_s1 = fmt_num( iv_val = ls_exch-exch_rate iv_dec = 5 ).
      lv_s2 = fmt_date( ls_exch-valid_from ).
      lv_s3 = fmt_num( iv_val = <ls_item>-variation iv_dec = 2 ).
      CONCATENATE 'Vigente en SAP:' lv_s1 'desde' lv_s2
                  '(variación' lv_s3 '%)'
             INTO lv_txt SEPARATED BY space.
      add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = <ls_item>-message ).

      lv_absv = abs( <ls_item>-variation ).
      IF lv_absv > p_desv.
        <ls_item>-warning = abap_true.
        lv_s1 = fmt_int( p_desv ).
        CONCATENATE 'ADVERTENCIA: la variación supera el'
                    lv_s1 '% configurado.'
               INTO lv_txt SEPARATED BY space.
        add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = <ls_item>-message ).
      ENDIF.
    ENDLOOP.
  ENDMETHOD.                    "check_sap

*======================================================================*
* Autorización previa: la BAPI controla S_TABU_DIS sobre V_TCURR con
* actividad de modificación. Se verifica antes para no llegar a la
* carga sin permisos. (Control informativo: la BAPI vuelve a validar.)
*======================================================================*
  METHOD check_auth.
    DATA lv_group TYPE tddat-cclass.

    rv_ok = abap_false.
    SELECT SINGLE cclass FROM tddat INTO lv_group
           WHERE tabname = 'V_TCURR'.
    IF sy-subrc <> 0 OR lv_group IS INITIAL.
      lv_group = '&NC&'.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'S_TABU_DIS'
      ID 'ACTVT'     FIELD '02'
      ID 'DICBERCLS' FIELD lv_group.
    IF sy-subrc = 0.
      rv_ok = abap_true.
      RETURN.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'S_TABU_NAM'
      ID 'ACTVT' FIELD '02'
      ID 'TABLE' FIELD 'V_TCURR'.
    IF sy-subrc = 0.
      rv_ok = abap_true.
    ENDIF.
  ENDMETHOD.                    "check_auth

*======================================================================*
* Compuertas antes de la carga real
*======================================================================*
  METHOD can_load.
    DATA: lv_q   TYPE c LENGTH 400,
          lv_ans TYPE c LENGTH 1,
          lv_s1  TYPE string,
          lv_txt TYPE string.

    rv_ok = abap_false.

    IF mv_n_rej > 0.
      lv_s1 = fmt_int( mv_n_rej ).
      CONCATENATE 'Carga real cancelada: hay' lv_s1
                  'registro(s) rechazado(s). Corregir el archivo; no se hacen cargas parciales.'
             INTO mv_result SEPARATED BY space.
      RETURN.
    ENDIF.
    IF mv_n_acc = 0.
      mv_result = 'Carga real cancelada: no hay cotizaciones aceptadas.'.
      RETURN.
    ENDIF.
    IF mv_n_warn > 0 AND p_acept = abap_false.
      lv_s1 = fmt_int( mv_n_warn ).
      CONCATENATE 'Carga real cancelada: hay' lv_s1
                  'advertencia(s). Revisarlas en simulación y marcar "Acepto las advertencias".'
             INTO mv_result SEPARATED BY space.
      RETURN.
    ENDIF.
    IF check_auth( ) = abap_false.
      mv_result = 'Carga real cancelada: falta autorización S_TABU_DIS (o S_TABU_NAM) de modificación sobre V_TCURR.'.
      RETURN.
    ENDIF.

    lv_s1 = fmt_int( mv_n_acc ).
    CONCATENATE 'Se crearán' lv_s1
                'cotizaciones tipo M en SAP (todas o ninguna). ¿Continuar?'
           INTO lv_txt SEPARATED BY space.
    lv_q = lv_txt.
    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = 'SAP FX Free - Carga real'
        text_question         = lv_q
        text_button_1         = 'Cargar'
        text_button_2         = 'Cancelar'
        default_button        = '2'
        display_cancel_button = space
      IMPORTING
        answer                = lv_ans
      EXCEPTIONS
        text_not_found        = 1
        OTHERS                = 2.
    IF sy-subrc <> 0 OR lv_ans <> '1'.
      mv_result = 'Carga real cancelada por el usuario.'.
      RETURN.
    ENDIF.

    rv_ok = abap_true.
  ENDMETHOD.                    "can_load

*======================================================================*
* Carga real en UNA LUW.
* BAPI_EXCHRATE_CREATEMULTIPLE valida todas las líneas, bloquea TCURR
* y registra la grabación en update task. Si devuelve cualquier error
* (o el aviso I017 de recálculo por factores) se llama a
* BAPI_TRANSACTION_ROLLBACK y
* no queda nada grabado. Si todo está OK: BAPI_TRANSACTION_COMMIT con
* WAIT = 'X' y luego se relee cada cotización para confirmarla.
*======================================================================*
  METHOD load.
    DATA: lt_list TYPE STANDARD TABLE OF bapi1093_0,
          ls_list TYPE bapi1093_0,
          lt_ret  TYPE STANDARD TABLE OF bapiret2,
          ls_ret  TYPE bapiret2,
          ls_cret TYPE bapiret2,
          lv_upd  TYPE bapi1093_2-upd_allow,
          lv_chg  TYPE bapi1093_2-chg_fixed,
          lv_err  TYPE abap_bool,
          lv_txt  TYPE string.
    FIELD-SYMBOLS <ls_item> TYPE ty_item.

    LOOP AT mt_items ASSIGNING <ls_item> WHERE status = gc_st_acc.
      CLEAR ls_list.
      ls_list-rate_type   = <ls_item>-rate_type.
      ls_list-from_curr   = <ls_item>-from_curr.
      ls_list-to_currncy  = <ls_item>-to_currncy.
      ls_list-valid_from  = <ls_item>-valid_from.
      ls_list-exch_rate   = <ls_item>-rate_sap.      " notación directa
      ls_list-from_factor = <ls_item>-from_factor.   " leídos de SAP
      ls_list-to_factor   = <ls_item>-to_factor.
      APPEND ls_list TO lt_list.
    ENDLOOP.
    IF lt_list IS INITIAL.
      RETURN.
    ENDIF.

*   UPD_ALLOW vacío = nunca sobrescribir (E020 si ya existe).
*   CHG_FIXED vacío = no tocar tipos de cambio fijos.
*   DEV_ALLOW no se pasa: queda en su default '000' = sin control de
*   desviación en la BAPI (verificado en LBUS1093F02); la variación
*   se controla en este programa con advertencias.
    CLEAR: lv_upd, lv_chg.
    CALL FUNCTION 'BAPI_EXCHRATE_CREATEMULTIPLE'
      EXPORTING
        upd_allow     = lv_upd
        chg_fixed     = lv_chg
      TABLES
        exchrate_list = lt_list
        return        = lt_ret.

    LOOP AT lt_ret INTO ls_ret.
      lv_txt = msg_text2( ls_ret ).
      CONCATENATE ls_ret-type ls_ret-id ls_ret-number lv_txt
             INTO lv_txt SEPARATED BY space.
      APPEND lv_txt TO mt_bapi_msg.
      IF ls_ret-type CA 'EAX' OR ls_ret-number = '017'.
        lv_err = abap_true.
      ENDIF.
    ENDLOOP.
    IF lt_ret IS INITIAL.
*     Sin mensajes no se puede confirmar el resultado: por seguridad
*     se revierte.
      lv_err = abap_true.
      APPEND 'La BAPI no devolvió mensajes; se revierte por seguridad.' TO mt_bapi_msg.
    ENDIF.

    IF lv_err = abap_true.
*     Verificado en SE37: ROLLBACK WORK + BUFFER_REFRESH_ALL. Descarta
*     la llamada a MODIFY_TCURR registrada IN UPDATE TASK.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'
        IMPORTING
          return = ls_cret.
      LOOP AT mt_items ASSIGNING <ls_item> WHERE status = gc_st_acc.
        <ls_item>-status = gc_st_notl.
        add_msg( EXPORTING iv_text = 'No cargado: la BAPI devolvió errores y se revirtió toda la carga (ver mensajes BAPI).'
                 CHANGING  cv_msg  = <ls_item>-message ).
      ENDLOOP.
      mv_result = 'Carga revertida: la BAPI devolvió errores. No se grabó ninguna cotización.'.
      RETURN.
    ENDIF.

    CALL FUNCTION 'BAPI_TRANSACTION_COMMIT'
      EXPORTING
        wait   = 'X'
      IMPORTING
        return = ls_cret.
    IF ls_cret-type CA 'EAX'.
      lv_txt = msg_text2( ls_cret ).
      CONCATENATE 'COMMIT fallido:' lv_txt INTO lv_txt SEPARATED BY space.
      APPEND lv_txt TO mt_bapi_msg.
      LOOP AT mt_items ASSIGNING <ls_item> WHERE status = gc_st_acc.
        <ls_item>-status = gc_st_notl.
        add_msg( EXPORTING iv_text = 'No cargado: falló la actualización (revisar SM13 y OB08).'
                 CHANGING  cv_msg  = <ls_item>-message ).
      ENDLOOP.
      mv_result = 'El COMMIT falló: revisar SM13 y OB08 antes de reintentar.'.
      RETURN.
    ENDIF.

    verify_loaded( ).
  ENDMETHOD.                    "load

*======================================================================*
* Verificación posterior: relee cada cotización con GETDETAIL
*======================================================================*
  METHOD verify_loaded.
    DATA: lv_rtype TYPE bapi1093_1-rate_type,
          lv_fcurr TYPE bapi1093_1-from_curr,
          lv_tcurr TYPE bapi1093_1-to_currncy,
          lv_date  TYPE bapi1093_2-trans_date,
          ls_exch  TYPE bapi1093_0,
          ls_ret1  TYPE bapiret1,
          lv_s1    TYPE string,
          lv_bad   TYPE i.
    FIELD-SYMBOLS <ls_item> TYPE ty_item.

    LOOP AT mt_items ASSIGNING <ls_item> WHERE status = gc_st_acc.
      lv_rtype = <ls_item>-rate_type.
      lv_fcurr = <ls_item>-from_curr.
      lv_tcurr = <ls_item>-to_currncy.
      lv_date  = <ls_item>-valid_from.
      CLEAR: ls_exch, ls_ret1.
      CALL FUNCTION 'BAPI_EXCHANGERATE_GETDETAIL'
        EXPORTING
          rate_type  = lv_rtype
          from_curr  = lv_fcurr
          to_currncy = lv_tcurr
          date       = lv_date
        IMPORTING
          exch_rate  = ls_exch
          return     = ls_ret1.
      IF ls_exch-valid_from = <ls_item>-valid_from
         AND ls_exch-exch_rate = <ls_item>-rate_sap.
        <ls_item>-status = gc_st_load.
        add_msg( EXPORTING iv_text = 'Cargado y verificado con GETDETAIL.'
                 CHANGING  cv_msg  = <ls_item>-message ).
      ELSE.
        <ls_item>-status = gc_st_chk.
        lv_bad = lv_bad + 1.
        add_msg( EXPORTING iv_text = 'COMMIT correcto pero la relectura no coincide: revisar en OB08.'
                 CHANGING  cv_msg  = <ls_item>-message ).
      ENDIF.
    ENDLOOP.

    IF lv_bad = 0.
      mv_result = 'Carga real finalizada y verificada.'.
    ELSE.
      lv_s1 = fmt_int( lv_bad ).
      CONCATENATE 'Carga confirmada, pero' lv_s1
                  'cotización(es) no coinciden en la relectura: revisar OB08.'
             INTO mv_result SEPARATED BY space.
    ENDIF.
  ENDMETHOD.                    "verify_loaded

*======================================================================*
* Conteos
*======================================================================*
  METHOD count_status.
    DATA ls_item TYPE ty_item.

    CLEAR: mv_n_total, mv_n_acc, mv_n_warn, mv_n_rej, mv_n_omi,
           mv_n_load, mv_n_notl.
    LOOP AT mt_items INTO ls_item.
      mv_n_total = mv_n_total + 1.
      CASE ls_item-status.
        WHEN gc_st_acc.
          mv_n_acc = mv_n_acc + 1.
          IF ls_item-warning = abap_true.
            mv_n_warn = mv_n_warn + 1.
          ENDIF.
        WHEN gc_st_rej.
          mv_n_rej = mv_n_rej + 1.
        WHEN gc_st_omi.
          mv_n_omi = mv_n_omi + 1.
        WHEN gc_st_load.
          mv_n_load = mv_n_load + 1.
        WHEN gc_st_notl OR gc_st_chk.
          mv_n_notl = mv_n_notl + 1.
      ENDCASE.
    ENDLOOP.
  ENDMETHOD.                    "count_status

*======================================================================*
* Armado del log (resumen + una fila por registro + mensajes BAPI)
*======================================================================*
  METHOD build_output.
    DATA: ls_out   TYPE ty_out,
          ls_item  TYPE ty_item,
          lv_txt   TYPE string,
          lv_src   TYPE string,
          lv_one   TYPE string,
          lv_s1    TYPE string,
          lv_s2    TYPE string,
          lv_s3    TYPE string,
          lv_s4    TYPE string,
          lv_s5    TYPE string,
          lv_s6    TYPE string,
          lv_s7    TYPE string.

    CLEAR mt_out.

*   ---- Resumen -------------------------------------------------------
    CLEAR ls_out.
    ls_out-icon   = icon_information.
    ls_out-estado = 'RESUMEN'.
    CONCATENATE 'Archivo:' p_file INTO lv_txt SEPARATED BY space.
    ls_out-mensaje = lv_txt.
    APPEND ls_out TO mt_out.

    IF p_real = abap_true.
      ls_out-mensaje = 'Modo: CARGA REAL'.
    ELSE.
      ls_out-mensaje = 'Modo: SIMULACIÓN (no se modificó SAP)'.
    ENDIF.
    APPEND ls_out TO mt_out.

*   Fuentes y fechas presentes en el archivo
    LOOP AT mt_items INTO ls_item WHERE source IS NOT INITIAL.
      CONCATENATE ls_item-source ls_item-source_date
             INTO lv_one SEPARATED BY space.
      IF lv_src IS INITIAL.
        lv_src = lv_one.
      ELSEIF lv_src NS lv_one.
        CONCATENATE lv_src lv_one INTO lv_src SEPARATED BY ` / `.
      ENDIF.
    ENDLOOP.
    CONCATENATE 'Fuente y fecha del archivo:' lv_src
           INTO ls_out-mensaje SEPARATED BY space.
    APPEND ls_out TO mt_out.

    lv_s1 = fmt_int( mv_n_total ).
    lv_s2 = fmt_int( mv_n_acc ).
    lv_s3 = fmt_int( mv_n_warn ).
    lv_s4 = fmt_int( mv_n_rej ).
    lv_s5 = fmt_int( mv_n_omi ).
    lv_s6 = fmt_int( mv_n_load ).
    lv_s7 = fmt_int( mv_n_notl ).
    CONCATENATE 'Procesados:' lv_s1
                '| Aceptados:' lv_s2 '(con advertencia:' lv_s3 ')'
                '| Rechazados:' lv_s4
                '| Omitidos:' lv_s5
                '| Cargados:' lv_s6
                '| No cargados:' lv_s7
           INTO lv_txt SEPARATED BY space.
    ls_out-mensaje = lv_txt.
    APPEND ls_out TO mt_out.

    CONCATENATE 'Resultado:' mv_result INTO lv_txt SEPARATED BY space.
    ls_out-mensaje = lv_txt.
    APPEND ls_out TO mt_out.

*   ---- Registros -----------------------------------------------------
    LOOP AT mt_items INTO ls_item.
      CLEAR ls_out.
      CASE ls_item-status.
        WHEN gc_st_acc.
          IF ls_item-warning = abap_true.
            ls_out-icon   = icon_yellow_light.
            ls_out-estado = 'ADVERTENCIA'.
          ELSE.
            ls_out-icon   = icon_green_light.
            ls_out-estado = 'ACEPTADO'.
          ENDIF.
        WHEN gc_st_rej.
          ls_out-icon   = icon_red_light.
          ls_out-estado = 'RECHAZADO'.
        WHEN gc_st_omi.
          ls_out-icon   = icon_light_out.
          ls_out-estado = 'OMITIDO'.
        WHEN gc_st_load.
          ls_out-icon   = icon_okay.
          ls_out-estado = 'CARGADO'.
        WHEN gc_st_notl.
          ls_out-icon   = icon_cancel.
          ls_out-estado = 'NO CARGADO'.
        WHEN gc_st_chk.
          ls_out-icon   = icon_red_light.
          ls_out-estado = 'REVISAR OB08'.
      ENDCASE.
      ls_out-linea       = ls_item-line.
      ls_out-moneda      = ls_item-from_curr.
      ls_out-a_moneda    = ls_item-to_currncy.
      ls_out-tipo        = ls_item-rate_type.
      ls_out-fecha       = ls_item-valid_from.
      ls_out-tasa_origen = ls_item-rate_text.
      ls_out-tasa_sap    = ls_item-rate_sap.
      ls_out-factor_de   = ls_item-from_factor.
      ls_out-factor_a    = ls_item-to_factor.
      ls_out-tasa_vig    = ls_item-prev_rate.
      ls_out-fecha_vig   = ls_item-prev_date.
      IF ls_item-prev_rate IS NOT INITIAL.
        ls_out-variacion = fmt_num( iv_val = ls_item-variation iv_dec = 2 ).
      ENDIF.
      ls_out-fuente      = ls_item-source.
      ls_out-fecha_fte   = ls_item-source_date.
      ls_out-estado_csv  = ls_item-csv_status.
      ls_out-mensaje     = ls_item-message.
      ls_out-url         = ls_item-source_url.
      IF ls_out-moneda IS INITIAL.
        ls_out-moneda = ls_item-currency.
      ENDIF.
      APPEND ls_out TO mt_out.
    ENDLOOP.

*   ---- Mensajes devueltos por la BAPI de carga -----------------------
    LOOP AT mt_bapi_msg INTO lv_txt.
      CLEAR ls_out.
      ls_out-icon    = icon_message_information.
      ls_out-estado  = 'MENSAJE BAPI'.
      ls_out-mensaje = lv_txt.
      APPEND ls_out TO mt_out.
    ENDLOOP.
  ENDMETHOD.                    "build_output

*======================================================================*
* ALV (CL_SALV_TABLE)
*======================================================================*
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

    set_col( io_cols = lo_cols iv_name = 'ICON'        iv_long = 'Semáforo'
             iv_med = 'Semáforo'           iv_short = 'Sem.' ).
    set_col( io_cols = lo_cols iv_name = 'ESTADO'      iv_long = 'Estado'
             iv_med = 'Estado'             iv_short = 'Estado' ).
    set_col( io_cols = lo_cols iv_name = 'LINEA'       iv_long = 'Línea del CSV'
             iv_med = 'Línea CSV'          iv_short = 'Línea' ).
    set_col( io_cols = lo_cols iv_name = 'MONEDA'      iv_long = 'Moneda origen'
             iv_med = 'Moneda origen'      iv_short = 'De' ).
    set_col( io_cols = lo_cols iv_name = 'A_MONEDA'    iv_long = 'Moneda destino'
             iv_med = 'Moneda destino'     iv_short = 'A' ).
    set_col( io_cols = lo_cols iv_name = 'TIPO'        iv_long = 'Tipo de cotización'
             iv_med = 'Tipo cotiz.'        iv_short = 'Tipo' ).
    set_col( io_cols = lo_cols iv_name = 'FECHA'       iv_long = 'Válido desde'
             iv_med = 'Válido desde'       iv_short = 'Fecha' ).
    set_col( io_cols = lo_cols iv_name = 'TASA_ORIGEN' iv_long = 'Cotización fuente (por 1 unidad)'
             iv_med = 'Cotiz. fuente'      iv_short = 'Fuente' ).
    set_col( io_cols = lo_cols iv_name = 'TASA_SAP'    iv_long = 'Cotización SAP calculada'
             iv_med = 'Cotiz. SAP'         iv_short = 'Cotiz.SAP' ).
    set_col( io_cols = lo_cols iv_name = 'FACTOR_DE'   iv_long = 'Factor "de"'
             iv_med = 'Factor de'          iv_short = 'Fact.de' ).
    set_col( io_cols = lo_cols iv_name = 'FACTOR_A'    iv_long = 'Factor "a"'
             iv_med = 'Factor a'           iv_short = 'Fact.a' ).
    set_col( io_cols = lo_cols iv_name = 'TASA_VIG'    iv_long = 'Cotización vigente en SAP'
             iv_med = 'Cotiz. vigente'     iv_short = 'Vigente' ).
    set_col( io_cols = lo_cols iv_name = 'FECHA_VIG'   iv_long = 'Fecha cotización vigente'
             iv_med = 'Fecha vigente'      iv_short = 'F.vigente' ).
    set_col( io_cols = lo_cols iv_name = 'VARIACION'   iv_long = 'Variación (%)'
             iv_med = 'Variación %'        iv_short = 'Var.%' ).
    set_col( io_cols = lo_cols iv_name = 'FUENTE'      iv_long = 'Fuente'
             iv_med = 'Fuente'             iv_short = 'Fuente' ).
    set_col( io_cols = lo_cols iv_name = 'FECHA_FTE'   iv_long = 'Fecha de la fuente'
             iv_med = 'Fecha fuente'       iv_short = 'F.fuente' ).
    set_col( io_cols = lo_cols iv_name = 'ESTADO_CSV'  iv_long = 'Estado en el CSV'
             iv_med = 'Estado CSV'         iv_short = 'Est.CSV' ).
    set_col( io_cols = lo_cols iv_name = 'MENSAJE'     iv_long = 'Mensaje'
             iv_med = 'Mensaje'            iv_short = 'Mensaje' ).
    set_col( io_cols = lo_cols iv_name = 'URL'         iv_long = 'URL de la fuente'
             iv_med = 'URL fuente'         iv_short = 'URL' ).

    TRY.
        lo_colt ?= lo_cols->get_column( 'ICON' ).
        lo_colt->set_icon( if_salv_c_bool_sap=>true ).
      CATCH cx_salv_not_found.
    ENDTRY.

    lo_disp = lo_alv->get_display_settings( ).
    lo_disp->set_striped_pattern( abap_true ).
    IF p_real = abap_true.
      lv_title = 'SAP FX Free - CARGA REAL - log de cotizaciones'.
    ELSE.
      lv_title = 'SAP FX Free - SIMULACIÓN - log de cotizaciones'.
    ENDIF.
    lo_disp->set_list_header( lv_title ).

    lo_alv->display( ).
  ENDMETHOD.                    "display

*======================================================================*
* Utilidades
*======================================================================*
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

  METHOD msg_text1.
    CLEAR rv_text.
    IF is_ret-message IS NOT INITIAL.
      rv_text = is_ret-message.
    ELSEIF is_ret-id IS NOT INITIAL.
      MESSAGE ID is_ret-id TYPE 'I' NUMBER is_ret-number
              WITH is_ret-message_v1 is_ret-message_v2
                   is_ret-message_v3 is_ret-message_v4
              INTO rv_text.
    ENDIF.
  ENDMETHOD.                    "msg_text1

  METHOD msg_text2.
    CLEAR rv_text.
    IF is_ret-message IS NOT INITIAL.
      rv_text = is_ret-message.
    ELSEIF is_ret-id IS NOT INITIAL.
      MESSAGE ID is_ret-id TYPE 'I' NUMBER is_ret-number
              WITH is_ret-message_v1 is_ret-message_v2
                   is_ret-message_v3 is_ret-message_v4
              INTO rv_text.
    ENDIF.
  ENDMETHOD.                    "msg_text2

  METHOD fmt_num.
*   Formato con el separador decimal del usuario, sin miles y con
*   el signo adelante (WRITE lo pondría atrás).
    DATA: lv_abs TYPE p LENGTH 16 DECIMALS 9,
          lv_c   TYPE c LENGTH 40.
    lv_abs = abs( iv_val ).
    WRITE lv_abs TO lv_c LEFT-JUSTIFIED NO-GROUPING DECIMALS iv_dec.
    rv_text = lv_c.
    IF iv_val < 0.
      CONCATENATE '-' rv_text INTO rv_text.
    ENDIF.
  ENDMETHOD.                    "fmt_num

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
