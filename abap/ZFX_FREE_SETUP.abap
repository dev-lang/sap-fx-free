*&---------------------------------------------------------------------*
*& Report ZFX_FREE_SETUP
*&---------------------------------------------------------------------*
*& SAP FX Free - Alta de monedas (OY03 / V_CURC) y factores de
*& conversión (OBBS / V_TCURF) a partir de un CSV.
*&
*& Reglas de diseño:
*&  - Nunca escribe directo en TCURC/TCURT/TCURF: usa batch input sobre
*&    SM30 (las mismas pantallas y validaciones que la carga manual) y
*&    registra todo en la orden de customizing indicada.
*&  - Modo SIMULACIÓN por defecto: valida el archivo y lee SAP.
*&  - No modifica ni borra entradas existentes: si la moneda o el factor
*&    ya existen con los mismos valores se informa; si difieren, se
*&    rechaza la línea.
*&  - Cada alta se verifica releyendo TCURC / TCURF después del batch
*&    input (no se confía solo en los mensajes de SM30).
*&
*& Secuencias de pantallas grabadas en SHDB el 24.10.2026 (BAS 001):
*&  V_TCURF: SAPMSVMA 0100 (=UPD) > SAPLSPO1 0600 (=OPT1, aviso de
*&           factores) > SAPL0SAP 0120 (=NEWL) > SAPL0SAP 0120 (datos,
*&           /00) > SAPL0SAP 0120 (=SAVE) > SAPLSTRD 0300 (=LOCK)
*&  V_CURC : SAPMSVMA 0100 (=UPD) > SAPL0SAP 0060 (=NEWL) >
*&           SAPL0SAP 0061 (datos, /00) > SAPL0SAP 0061 (=SAVE) >
*&           SAPLSTRD 0300 (=LOCK)
*&
*& Compatibilidad: SAP_BASIS 731 (sin sintaxis 7.40+).
*& Versión 1.1 - 24.10.2026 (cierre de SM30 al final del batch input)
*& Versión 1.2 - 24.10.2026 (log completo del batch input si falla)
*&---------------------------------------------------------------------*
REPORT zfx_free_setup.

TYPE-POOLS: abap, icon.

*----------------------------------------------------------------------*
* Tipos
*----------------------------------------------------------------------*
TYPES: ty_t_string TYPE STANDARD TABLE OF string WITH DEFAULT KEY.

TYPES: BEGIN OF ty_record,
         line   TYPE i,
         fields TYPE ty_t_string,
       END OF ty_record,
       ty_t_record TYPE STANDARD TABLE OF ty_record WITH DEFAULT KEY.

TYPES: BEGIN OF ty_item,
         line        TYPE i,
         status      TYPE c LENGTH 1,     " ver gc_st_*
         warning     TYPE abap_bool,
         waers       TYPE tcurc-waers,
         isocd       TYPE tcurc-isocd,
         altwr       TYPE tcurc-altwr,
         ltext       TYPE string,
         ktext       TYPE string,
         kurst       TYPE tcurf-kurst,
         tcurr       TYPE tcurf-tcurr,
         valid_from  TYPE d,
         ffact       TYPE tcurf-ffact,
         tfact       TYPE tcurf-tfact,
         cur_new     TYPE abap_bool,      " hay que crear la moneda
         cur_done    TYPE abap_bool,      " moneda creada en esta corrida
         fac_new     TYPE abap_bool,      " hay que crear el factor
         fac_done    TYPE abap_bool,      " factor creado en esta corrida
         message     TYPE string,
       END OF ty_item,
       ty_t_item TYPE STANDARD TABLE OF ty_item WITH DEFAULT KEY.

TYPES: BEGIN OF ty_out,
         icon      TYPE icon_d,
         estado    TYPE c LENGTH 15,
         linea     TYPE i,
         moneda    TYPE waers,
         accion_m  TYPE c LENGTH 12,
         iso       TYPE c LENGTH 3,
         texto     TYPE c LENGTH 40,
         tipo      TYPE kurst_curr,
         a_moneda  TYPE waers,
         fecha     TYPE d,
         factor_de TYPE ffact_curr,
         factor_a  TYPE tfact_curr,
         accion_f  TYPE c LENGTH 12,
         mensaje   TYPE c LENGTH 255,
       END OF ty_out,
       ty_t_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

CONSTANTS:
  gc_max_bytes TYPE i VALUE 1048576,
  gc_st_ok     TYPE c LENGTH 1 VALUE 'A',  " válido, hay algo para crear
  gc_st_noth   TYPE c LENGTH 1 VALUE 'E',  " ya existe todo, nada que hacer
  gc_st_rej    TYPE c LENGTH 1 VALUE 'R',  " rechazado (bloquea la ejecución)
  gc_st_done   TYPE c LENGTH 1 VALUE 'L',  " creado y verificado
  gc_st_fail   TYPE c LENGTH 1 VALUE 'F',  " falló el batch input
  gc_st_skip   TYPE c LENGTH 1 VALUE 'S'.  " no procesado (corte por error)

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
SELECTION-SCREEN COMMENT 1(31) c_trkorr FOR FIELD p_trkorr.
PARAMETERS p_trkorr TYPE e070-trkorr.
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
SELECTION-SCREEN COMMENT 1(31) c_mode FOR FIELD p_mode.
PARAMETERS p_mode(1) TYPE c DEFAULT 'N'.
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

    DATA: mt_items   TYPE ty_t_item,
          mt_out     TYPE ty_t_out,
          mt_cols    TYPE ty_t_col,
          mt_req     TYPE ty_t_string,
          mt_bdc     TYPE STANDARD TABLE OF bdcdata,
          mv_ncols   TYPE i,
          mv_result  TYPE string,
          mv_n_total TYPE i,
          mv_n_ok    TYPE i,
          mv_n_noth  TYPE i,
          mv_n_rej   TYPE i,
          mv_n_warn  TYPE i,
          mv_n_done  TYPE i,
          mv_n_fail  TYPE i,
          mv_n_cur   TYPE i,
          mv_n_fac   TYPE i.

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
    METHODS check_factor_value
      IMPORTING iv_text      TYPE string
      EXPORTING ev_value     TYPE i
                ev_error     TYPE string.
    METHODS check_request
      RETURNING value(rv_error) TYPE string.
    METHODS can_execute
      RETURNING value(rv_ok) TYPE abap_bool.
    METHODS execute.
    METHODS create_currency
      CHANGING cs_item TYPE ty_item.
    METHODS create_factor
      CHANGING cs_item TYPE ty_item.
    METHODS call_sm30
      EXPORTING ev_text TYPE string.
    METHODS bdc_dynpro
      IMPORTING iv_program TYPE csequence
                iv_dynpro  TYPE csequence.
    METHODS bdc_field
      IMPORTING iv_fnam TYPE csequence
                iv_fval TYPE csequence.
    METHODS currency_exists
      IMPORTING iv_waers     TYPE tcurc-waers
      RETURNING value(rv_ok) TYPE abap_bool.
    METHODS count_status.
    METHODS build_output.
    METHODS display.

    CLASS-METHODS add_msg
      IMPORTING iv_text TYPE string
      CHANGING  cv_msg  TYPE string.
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
  t_b01    = 'Archivo y orden de transporte'.
  t_b02    = 'Modo de ejecución'.
  t_b03    = 'Controles'.
  c_file   = 'CSV de monedas y factores'.
  c_trkorr = 'Orden de customizing'.
  c_sim    = 'Simulación: valida y muestra el log, no modifica SAP'.
  c_real   = 'Ejecución real: crea por SM30 (pide confirmación)'.
  c_mode   = 'Modo batch input (N/E/A)'.
  c_acept  = 'Acepto las advertencias revisadas (solo ejecución real)'.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  lcl_app=>f4_file( CHANGING cv_file = p_file ).

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

  METHOD constructor.
*   Contrato del CSV de configuración
    APPEND 'currency'    TO mt_req.
    APPEND 'iso_code'    TO mt_req.
    APPEND 'alt_key'     TO mt_req.
    APPEND 'long_text'   TO mt_req.
    APPEND 'short_text'  TO mt_req.
    APPEND 'rate_type'   TO mt_req.
    APPEND 'to_currency' TO mt_req.
    APPEND 'valid_from'  TO mt_req.
    APPEND 'from_factor' TO mt_req.
    APPEND 'to_factor'   TO mt_req.
  ENDMETHOD.                    "constructor

  METHOD f4_file.
    DATA: lt_files  TYPE filetable,
          ls_file   TYPE file_table,
          lv_rc     TYPE i,
          lv_action TYPE i.

    cl_gui_frontend_services=>file_open_dialog(
      EXPORTING
        window_title            = 'Seleccionar CSV de monedas y factores'
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
          lv_s1      TYPE string,
          lv_s2      TYPE string.

    IF sy-batch = abap_true.
      MESSAGE 'Ejecutar en diálogo: el archivo se lee desde SAP GUI.'
        TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    read_file( EXPORTING iv_file    = p_file
               IMPORTING ev_content = lv_content
                         ev_error   = lv_error ).
    IF lv_error IS NOT INITIAL.
      MESSAGE lv_error TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    parse_csv( EXPORTING iv_content = lv_content
               IMPORTING et_records = lt_records
                         ev_error   = lv_error ).
    IF lv_error IS NOT INITIAL.
      MESSAGE lv_error TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.
    lv_n = lines( lt_records ).
    IF lv_n < 2.
      MESSAGE 'El archivo no tiene cabecera y al menos una línea.'
        TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    READ TABLE lt_records INTO ls_record INDEX 1.
    map_header( EXPORTING is_header = ls_record
                IMPORTING ev_error  = lv_error ).
    IF lv_error IS NOT INITIAL.
      MESSAGE lv_error TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    LOOP AT lt_records INTO ls_record FROM 2.
      ls_item = check_record( ls_record ).
      APPEND ls_item TO mt_items.
    ENDLOOP.

    check_duplicates( ).
    check_sap( ).
    count_status( ).

    IF p_real = abap_true.
      IF can_execute( ) = abap_true.
        execute( ).
        count_status( ).
      ENDIF.
    ELSE.
      lv_s1 = fmt_int( mv_n_cur ).
      lv_s2 = fmt_int( mv_n_fac ).
      CONCATENATE 'Simulación finalizada: no se modificó SAP. Se crearían'
                  lv_s1 'moneda(s) y' lv_s2 'factor(es).'
             INTO mv_result SEPARATED BY space.
    ENDIF.

    build_output( ).
    MESSAGE mv_result TYPE 'S'.
    display( ).
  ENDMETHOD.                    "run

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
* Validación de contenido (sin consultar SAP)
*======================================================================*
  METHOD check_record.
    DATA: lv_cur   TYPE string,
          lv_iso   TYPE string,
          lv_alt   TYPE string,
          lv_rtype TYPE string,
          lv_to    TYPE string,
          lv_date  TYPE string,
          lv_ff    TYPE string,
          lv_tf    TYPE string,
          lv_err   TYPE string,
          lv_s1    TYPE string,
          lv_s2    TYPE string,
          lv_dc    TYPE c LENGTH 8,
          lv_d2    TYPE d,
          lv_days  TYPE i,
          lv_n     TYPE i,
          lv_len   TYPE i,
          lv_fval  TYPE i,
          lv_tval  TYPE i.

    rs_item-line   = is_rec-line.
    rs_item-status = gc_st_rej.

    lv_n = lines( is_rec-fields ).
    IF lv_n <> mv_ncols.
      lv_s1 = fmt_int( lv_n ).
      lv_s2 = fmt_int( mv_ncols ).
      CONCATENATE 'La línea tiene' lv_s1 'columnas; la cabecera tiene'
                  lv_s2 '.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.

    lv_cur          = get_value( is_rec = is_rec iv_name = 'currency' ).
    lv_iso          = get_value( is_rec = is_rec iv_name = 'iso_code' ).
    lv_alt          = get_value( is_rec = is_rec iv_name = 'alt_key' ).
    rs_item-ltext   = get_value( is_rec = is_rec iv_name = 'long_text' ).
    rs_item-ktext   = get_value( is_rec = is_rec iv_name = 'short_text' ).
    lv_rtype        = get_value( is_rec = is_rec iv_name = 'rate_type' ).
    lv_to           = get_value( is_rec = is_rec iv_name = 'to_currency' ).
    lv_date         = get_value( is_rec = is_rec iv_name = 'valid_from' ).
    lv_ff           = get_value( is_rec = is_rec iv_name = 'from_factor' ).
    lv_tf           = get_value( is_rec = is_rec iv_name = 'to_factor' ).

    CONDENSE: lv_cur, lv_iso, lv_alt, rs_item-ltext, rs_item-ktext,
              lv_rtype, lv_to, lv_date, lv_ff, lv_tf.
    TRANSLATE: lv_cur TO UPPER CASE, lv_iso TO UPPER CASE,
               lv_rtype TO UPPER CASE, lv_to TO UPPER CASE.

*   Moneda
    FIND REGEX '^[A-Z0-9]{1,5}$' IN lv_cur.
    IF sy-subrc <> 0.
      CONCATENATE 'Código de moneda' lv_cur 'inválido (1 a 5 letras o dígitos).'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    rs_item-waers = lv_cur.

    IF lv_iso IS NOT INITIAL.
      FIND REGEX '^[A-Z]{3}$' IN lv_iso.
      IF sy-subrc <> 0.
        CONCATENATE 'Código ISO' lv_iso 'inválido (3 letras).'
               INTO rs_item-message SEPARATED BY space.
        RETURN.
      ENDIF.
      rs_item-isocd = lv_iso.
    ENDIF.
    IF lv_alt IS NOT INITIAL.
      FIND REGEX '^\d{3}$' IN lv_alt.
      IF sy-subrc <> 0.
        CONCATENATE 'Clave alternativa' lv_alt 'inválida (3 dígitos).'
               INTO rs_item-message SEPARATED BY space.
        RETURN.
      ENDIF.
      rs_item-altwr = lv_alt.
    ENDIF.
    lv_len = strlen( rs_item-ltext ).
    IF lv_len > 40.
      rs_item-message = 'long_text supera 40 caracteres.'.
      RETURN.
    ENDIF.
    lv_len = strlen( rs_item-ktext ).
    IF lv_len > 15.
      rs_item-message = 'short_text supera 15 caracteres.'.
      RETURN.
    ENDIF.

*   Factor
    FIND REGEX '^[A-Z0-9]{1,4}$' IN lv_rtype.
    IF sy-subrc <> 0.
      CONCATENATE 'Tipo de cotización' lv_rtype 'inválido.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    rs_item-kurst = lv_rtype.
    FIND REGEX '^[A-Z0-9]{1,5}$' IN lv_to.
    IF sy-subrc <> 0.
      CONCATENATE 'Moneda destino' lv_to 'inválida.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    rs_item-tcurr = lv_to.
    IF rs_item-tcurr = rs_item-waers.
      rs_item-message = 'Moneda origen y destino iguales.'.
      RETURN.
    ENDIF.

    FIND REGEX '^\d{4}-\d{2}-\d{2}$' IN lv_date.
    IF sy-subrc <> 0.
      CONCATENATE 'Fecha valid_from' lv_date 'con formato inválido: se espera AAAA-MM-DD.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    CONCATENATE lv_date+0(4) lv_date+5(2) lv_date+8(2) INTO lv_dc.
    rs_item-valid_from = lv_dc.
    lv_days = rs_item-valid_from.
    lv_d2   = lv_days.
    IF lv_days = 0 OR lv_d2 <> rs_item-valid_from.
      CONCATENATE 'Fecha valid_from' lv_date 'inexistente en el calendario.'
             INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.

    check_factor_value( EXPORTING iv_text  = lv_ff
                        IMPORTING ev_value = lv_fval
                                  ev_error = lv_err ).
    IF lv_err IS NOT INITIAL.
      CONCATENATE 'from_factor:' lv_err INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
    check_factor_value( EXPORTING iv_text  = lv_tf
                        IMPORTING ev_value = lv_tval
                                  ev_error = lv_err ).
    IF lv_err IS NOT INITIAL.
      CONCATENATE 'to_factor:' lv_err INTO rs_item-message SEPARATED BY space.
      RETURN.
    ENDIF.
*   Misma regla que la BAPI de cotizaciones: uno de los dos debe ser 1
    IF lv_fval <> 1 AND lv_tval <> 1.
      rs_item-message = 'Uno de los dos factores debe ser 1.'.
      RETURN.
    ENDIF.
    rs_item-ffact = lv_fval.
    rs_item-tfact = lv_tval.

    rs_item-status = gc_st_ok.
  ENDMETHOD.                    "check_record

*----------------------------------------------------------------------*
* Factor: entero, potencia de 10 entre 1 y 1.000.000.000
*----------------------------------------------------------------------*
  METHOD check_factor_value.
    DATA: lv_rest TYPE i,
          lv_mod  TYPE i,
          lv_bad  TYPE abap_bool.

    CLEAR: ev_value, ev_error.
    FIND REGEX '^\d{1,10}$' IN iv_text.
    IF sy-subrc <> 0.
      CONCATENATE iv_text 'no es un entero positivo.' INTO ev_error SEPARATED BY space.
      RETURN.
    ENDIF.
    TRY.
        ev_value = iv_text.
      CATCH cx_sy_conversion_overflow cx_sy_conversion_no_number.
        lv_bad = abap_true.
    ENDTRY.
    IF lv_bad = abap_true OR ev_value <= 0 OR ev_value > 1000000000.
      CONCATENATE iv_text 'fuera de rango (1 a 1.000.000.000).' INTO ev_error SEPARATED BY space.
      RETURN.
    ENDIF.
    lv_rest = ev_value.
    lv_mod  = lv_rest MOD 10.
    WHILE lv_rest >= 10 AND lv_mod = 0.
      lv_rest = lv_rest DIV 10.
      lv_mod  = lv_rest MOD 10.
    ENDWHILE.
    IF lv_rest <> 1.
      CONCATENATE iv_text 'no es potencia de 10 (1, 10, 100, ...).' INTO ev_error SEPARATED BY space.
    ENDIF.
  ENDMETHOD.                    "check_factor_value

*----------------------------------------------------------------------*
* Duplicados en el archivo: misma clave de factor
*----------------------------------------------------------------------*
  METHOD check_duplicates.
    DATA: lt_copy  TYPE ty_t_item,
          ls_other TYPE ty_item,
          lv_n     TYPE i,
          lv_lines TYPE string,
          lv_s1    TYPE string.
    FIELD-SYMBOLS <ls_item> TYPE ty_item.

    lt_copy = mt_items.
    LOOP AT mt_items ASSIGNING <ls_item> WHERE status = gc_st_ok.
      CLEAR: lv_n, lv_lines.
      LOOP AT lt_copy INTO ls_other
           WHERE status     = gc_st_ok
             AND waers      = <ls_item>-waers
             AND kurst      = <ls_item>-kurst
             AND tcurr      = <ls_item>-tcurr
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
        CONCATENATE 'Duplicado en el archivo (mismo tipo, par y fecha) en las líneas'
                    lv_lines
               INTO <ls_item>-message SEPARATED BY space.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.                    "check_duplicates

*======================================================================*
* Validaciones contra SAP (solo lectura de TCURC, TCURV, TCURF, TCURR)
*======================================================================*
  METHOD check_sap.
    DATA: ls_tcurf  TYPE tcurf,
          lv_inv    TYPE tcurf-gdatu,
          lv_kurst  TYPE tcurv-kurst,
          lv_cnt    TYPE i,
          lv_i      TYPE i,
          lv_txt    TYPE string,
          lv_s1     TYPE string,
          lv_s2     TYPE string,
          lv_tc_ok  TYPE abap_bool.
    FIELD-SYMBOLS: <ls_item> TYPE ty_item,
                   <ls_oth>  TYPE ty_item.

    LOOP AT mt_items ASSIGNING <ls_item> WHERE status = gc_st_ok.

*     ---- Moneda origen -------------------------------------------
      IF currency_exists( <ls_item>-waers ) = abap_true.
        <ls_item>-cur_new = abap_false.
      ELSE.
        IF <ls_item>-ltext IS INITIAL OR <ls_item>-ktext IS INITIAL.
          <ls_item>-status  = gc_st_rej.
          <ls_item>-message = 'La moneda no existe en TCURC y faltan long_text/short_text para crearla.'.
          CONTINUE.
        ENDIF.
*       Si la misma moneda aparece en varias líneas, se crea una vez
        <ls_item>-cur_new = abap_true.
        LOOP AT mt_items ASSIGNING <ls_oth>
             WHERE waers   = <ls_item>-waers
               AND cur_new = abap_true
               AND line    < <ls_item>-line.
          <ls_item>-cur_new = abap_false.
          EXIT.
        ENDLOOP.
      ENDIF.

*     ---- Tipo de cotización ---------------------------------------
      SELECT SINGLE kurst FROM tcurv INTO lv_kurst
             WHERE kurst = <ls_item>-kurst.
      IF sy-subrc <> 0.
        <ls_item>-status = gc_st_rej.
        CONCATENATE 'Tipo de cotización' <ls_item>-kurst 'inexistente en TCURV (OB07).'
               INTO <ls_item>-message SEPARATED BY space.
        CONTINUE.
      ENDIF.

*     ---- Moneda destino (en SAP o creada en este mismo archivo) -----
      lv_tc_ok = currency_exists( <ls_item>-tcurr ).
      IF lv_tc_ok = abap_false.
        READ TABLE mt_items TRANSPORTING NO FIELDS
             WITH KEY waers = <ls_item>-tcurr.
        IF sy-subrc = 0.
          lv_tc_ok = abap_true.
        ENDIF.
      ENDIF.
      IF lv_tc_ok = abap_false.
        <ls_item>-status = gc_st_rej.
        CONCATENATE 'Moneda destino' <ls_item>-tcurr 'inexistente en TCURC.'
               INTO <ls_item>-message SEPARATED BY space.
        CONTINUE.
      ENDIF.

*     ---- Factor: misma clave ya existente ---------------------------
*     TCURF-GDATU guarda la fecha invertida (99999999 - AAAAMMDD)
      lv_inv = <ls_item>-valid_from.
      TRANSLATE lv_inv USING '09182736455463728190'.
      SELECT SINGLE * FROM tcurf INTO ls_tcurf
             WHERE kurst = <ls_item>-kurst
               AND fcurr = <ls_item>-waers
               AND tcurr = <ls_item>-tcurr
               AND gdatu = lv_inv.
      IF sy-subrc = 0.
        IF ls_tcurf-ffact = <ls_item>-ffact AND ls_tcurf-tfact = <ls_item>-tfact.
          <ls_item>-fac_new = abap_false.
          add_msg( EXPORTING iv_text = 'El factor ya existe con los mismos valores.'
                   CHANGING  cv_msg  = <ls_item>-message ).
        ELSE.
          lv_i = ls_tcurf-ffact.
          lv_s1 = fmt_int( lv_i ).
          lv_i = ls_tcurf-tfact.
          lv_s2 = fmt_int( lv_i ).
          CONCATENATE 'El factor ya existe en OBBS con' lv_s1 ':' lv_s2
                      'y el archivo trae otros valores. No se modifica: resolver a mano.'
                 INTO lv_txt SEPARATED BY space.
          <ls_item>-status  = gc_st_rej.
          <ls_item>-message = lv_txt.
          CONTINUE.
        ENDIF.
      ELSE.
        <ls_item>-fac_new = abap_true.
*       Otras fechas para el mismo par: el nuevo factor cambia la
*       interpretación de cotizaciones a partir de su fecha.
        SELECT COUNT(*) FROM tcurf INTO lv_cnt
               WHERE kurst = <ls_item>-kurst
                 AND fcurr = <ls_item>-waers
                 AND tcurr = <ls_item>-tcurr.
        IF lv_cnt > 0.
          <ls_item>-warning = abap_true.
          add_msg( EXPORTING iv_text = 'ADVERTENCIA: ya hay factores para este par con otra fecha.'
                   CHANGING  cv_msg  = <ls_item>-message ).
        ENDIF.
*       Cotizaciones existentes del par: es el riesgo del aviso de OBBS
        SELECT COUNT(*) FROM tcurr INTO lv_cnt
               WHERE kurst = <ls_item>-kurst
                 AND fcurr = <ls_item>-waers
                 AND tcurr = <ls_item>-tcurr.
        IF lv_cnt > 0.
          <ls_item>-warning = abap_true.
          lv_s1 = fmt_int( lv_cnt ).
          CONCATENATE 'ADVERTENCIA: el par ya tiene' lv_s1
                      'cotización(es) en TCURR; un factor nuevo puede cambiar su interpretación.'
                 INTO lv_txt SEPARATED BY space.
          add_msg( EXPORTING iv_text = lv_txt CHANGING cv_msg = <ls_item>-message ).
        ENDIF.
      ENDIF.

      IF <ls_item>-cur_new = abap_false AND <ls_item>-fac_new = abap_false.
        <ls_item>-status = gc_st_noth.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.                    "check_sap

  METHOD currency_exists.
    DATA lv_waers TYPE tcurc-waers.
    rv_ok = abap_false.
    SELECT SINGLE waers FROM tcurc INTO lv_waers WHERE waers = iv_waers.
    IF sy-subrc = 0.
      rv_ok = abap_true.
    ENDIF.
  ENDMETHOD.                    "currency_exists

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
          lv_s1  TYPE string,
          lv_s2  TYPE string,
          lv_txt TYPE string,
          lv_q   TYPE c LENGTH 400,
          lv_ans TYPE c LENGTH 1.

    rv_ok = abap_false.
    IF mv_n_rej > 0.
      lv_s1 = fmt_int( mv_n_rej ).
      CONCATENATE 'Ejecución cancelada: hay' lv_s1
                  'línea(s) rechazada(s). Corregir el archivo.'
             INTO mv_result SEPARATED BY space.
      RETURN.
    ENDIF.
    IF mv_n_cur = 0 AND mv_n_fac = 0.
      mv_result = 'Nada para crear: todas las monedas y factores ya existen.'.
      RETURN.
    ENDIF.
    IF mv_n_warn > 0 AND p_acept = abap_false.
      lv_s1 = fmt_int( mv_n_warn ).
      CONCATENATE 'Ejecución cancelada: hay' lv_s1
                  'advertencia(s). Revisarlas y marcar "Acepto las advertencias".'
             INTO mv_result SEPARATED BY space.
      RETURN.
    ENDIF.
    lv_err = check_request( ).
    IF lv_err IS NOT INITIAL.
      CONCATENATE 'Ejecución cancelada:' lv_err INTO mv_result SEPARATED BY space.
      RETURN.
    ENDIF.

    lv_s1 = fmt_int( mv_n_cur ).
    lv_s2 = fmt_int( mv_n_fac ).
    CONCATENATE 'Se crearán por SM30' lv_s1 'moneda(s) y' lv_s2
                'factor(es) en la orden' p_trkorr '. ¿Continuar?'
           INTO lv_txt SEPARATED BY space.
    lv_q = lv_txt.
    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = 'SAP FX Free - Monedas y factores'
        text_question         = lv_q
        text_button_1         = 'Ejecutar'
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
* Ejecución: primero todas las monedas, después los factores.
* SM30 graba y confirma cada alta por separado: no hay una LUW única.
* Ante el primer error se corta para no dejar factores sin moneda.
*======================================================================*
  METHOD execute.
    DATA: lv_stop TYPE abap_bool,
          lv_s1   TYPE string,
          lv_s2   TYPE string,
          lv_cnt  TYPE i.
    FIELD-SYMBOLS <ls_item> TYPE ty_item.

*   1) Monedas
    LOOP AT mt_items ASSIGNING <ls_item>
         WHERE status = gc_st_ok AND cur_new = abap_true.
      create_currency( CHANGING cs_item = <ls_item> ).
      IF <ls_item>-status = gc_st_fail.
        lv_stop = abap_true.
        EXIT.
      ENDIF.
    ENDLOOP.

*   2) Factores
    IF lv_stop = abap_false.
      LOOP AT mt_items ASSIGNING <ls_item>
           WHERE status = gc_st_ok AND fac_new = abap_true.
        create_factor( CHANGING cs_item = <ls_item> ).
        IF <ls_item>-status = gc_st_fail.
          lv_stop = abap_true.
          EXIT.
        ENDIF.
      ENDLOOP.
    ENDIF.

*   3) Estado final de cada línea
    LOOP AT mt_items ASSIGNING <ls_item> WHERE status = gc_st_ok.
      IF ( <ls_item>-cur_new = abap_false OR <ls_item>-cur_done = abap_true )
         AND ( <ls_item>-fac_new = abap_false OR <ls_item>-fac_done = abap_true ).
        <ls_item>-status = gc_st_done.
      ELSE.
        <ls_item>-status = gc_st_skip.
        add_msg( EXPORTING iv_text = 'No procesado: la ejecución se detuvo por un error anterior.'
                 CHANGING  cv_msg  = <ls_item>-message ).
      ENDIF.
    ENDLOOP.

    LOOP AT mt_items TRANSPORTING NO FIELDS WHERE status = gc_st_fail.
      lv_cnt = lv_cnt + 1.
    ENDLOOP.
    IF lv_stop = abap_true.
      lv_s1 = fmt_int( lv_cnt ).
      CONCATENATE 'Ejecución detenida:' lv_s1
                  'error(es) de batch input. Lo creado antes del error queda en la orden'
                  p_trkorr '.'
             INTO mv_result SEPARATED BY space.
    ELSE.
      lv_s1 = fmt_int( mv_n_cur ).
      lv_s2 = fmt_int( mv_n_fac ).
      CONCATENATE 'Ejecución finalizada:' lv_s1 'moneda(s) y' lv_s2
                  'factor(es) creados y verificados en la orden' p_trkorr '.'
             INTO mv_result SEPARATED BY space.
    ENDIF.
  ENDMETHOD.                    "execute

*----------------------------------------------------------------------*
* Alta de moneda por SM30 / V_CURC
*----------------------------------------------------------------------*
  METHOD create_currency.
    DATA: lv_text TYPE string,
          lv_ltx  TYPE c LENGTH 40,
          lv_ktx  TYPE c LENGTH 15.

    lv_ltx = cs_item-ltext.
    lv_ktx = cs_item-ktext.

    CLEAR mt_bdc.
    bdc_dynpro( iv_program = 'SAPMSVMA' iv_dynpro = '0100' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=UPD' ).
    bdc_field( iv_fnam = 'VIEWNAME'                iv_fval = 'V_CURC' ).
    bdc_field( iv_fnam = 'VIMDYNFLDS-LTD_DTA_NO'   iv_fval = 'X' ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0060' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=NEWL' ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0061' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '/00' ).
    bdc_field( iv_fnam = 'V_CURC-WAERS'            iv_fval = cs_item-waers ).
    bdc_field( iv_fnam = 'V_CURC-LTEXT'            iv_fval = lv_ltx ).
    bdc_field( iv_fnam = 'V_CURC-KTEXT'            iv_fval = lv_ktx ).
    bdc_field( iv_fnam = 'V_CURC-ISOCD'            iv_fval = cs_item-isocd ).
    bdc_field( iv_fnam = 'V_CURC-ALTWR'            iv_fval = cs_item-altwr ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0061' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=SAVE' ).
    bdc_dynpro( iv_program = 'SAPLSTRD' iv_dynpro = '0300' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=LOCK' ).
    bdc_field( iv_fnam = 'KO008-TRKORR'            iv_fval = p_trkorr ).
*   Cierre de SM30 (secuencia observada en la prueba real del 24.10.2026)
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0061' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=BACK' ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0060' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=BACK' ).
    bdc_dynpro( iv_program = 'SAPMSVMA' iv_dynpro = '0100' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '/EBACK' ).

    call_sm30( IMPORTING ev_text = lv_text ).

*   Verificación: la moneda tiene que existir ahora en TCURC
    IF currency_exists( cs_item-waers ) = abap_true.
      cs_item-cur_done = abap_true.
      add_msg( EXPORTING iv_text = 'Moneda creada y verificada en TCURC.'
               CHANGING  cv_msg  = cs_item-message ).
    ELSE.
      cs_item-status = gc_st_fail.
      CONCATENATE 'No se creó la moneda (SM30):' lv_text INTO lv_text SEPARATED BY space.
      add_msg( EXPORTING iv_text = lv_text CHANGING cv_msg = cs_item-message ).
    ENDIF.
  ENDMETHOD.                    "create_currency

*----------------------------------------------------------------------*
* Alta de factor por SM30 / V_TCURF
*----------------------------------------------------------------------*
  METHOD create_factor.
    DATA: lv_text  TYPE string,
          lv_date  TYPE c LENGTH 10,
          lv_ff    TYPE c LENGTH 12,
          lv_tf    TYPE c LENGTH 12,
          lv_inv   TYPE tcurf-gdatu,
          ls_tcurf TYPE tcurf.

    WRITE cs_item-valid_from TO lv_date.          " formato del usuario
    WRITE cs_item-ffact TO lv_ff LEFT-JUSTIFIED NO-GROUPING DECIMALS 0.
    WRITE cs_item-tfact TO lv_tf LEFT-JUSTIFIED NO-GROUPING DECIMALS 0.

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
    bdc_field( iv_fnam = 'V_TCURF-KURST(01)'       iv_fval = cs_item-kurst ).
    bdc_field( iv_fnam = 'V_TCURF-FCURR(01)'       iv_fval = cs_item-waers ).
    bdc_field( iv_fnam = 'V_TCURF-TCURR(01)'       iv_fval = cs_item-tcurr ).
    bdc_field( iv_fnam = 'V_TCURF-GDATU(01)'       iv_fval = lv_date ).
    bdc_field( iv_fnam = 'V_TCURF-FFACT(01)'       iv_fval = lv_ff ).
    bdc_field( iv_fnam = 'V_TCURF-TFACT(01)'       iv_fval = lv_tf ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0120' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=SAVE' ).
    bdc_dynpro( iv_program = 'SAPLSTRD' iv_dynpro = '0300' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=LOCK' ).
    bdc_field( iv_fnam = 'KO008-TRKORR'            iv_fval = p_trkorr ).
*   Cierre de SM30 (secuencia grabada en SHDB ZFX_TCURF)
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0120' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=BACK' ).
    bdc_dynpro( iv_program = 'SAPL0SAP' iv_dynpro = '0120' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '=BACK' ).
    bdc_dynpro( iv_program = 'SAPMSVMA' iv_dynpro = '0100' ).
    bdc_field( iv_fnam = 'BDC_OKCODE'              iv_fval = '/EBACK' ).

    call_sm30( IMPORTING ev_text = lv_text ).

*   Verificación: la entrada tiene que existir con los factores pedidos
*   TCURF-GDATU guarda la fecha invertida (99999999 - AAAAMMDD)
    lv_inv = cs_item-valid_from.
    TRANSLATE lv_inv USING '09182736455463728190'.
    SELECT SINGLE * FROM tcurf INTO ls_tcurf
           WHERE kurst = cs_item-kurst
             AND fcurr = cs_item-waers
             AND tcurr = cs_item-tcurr
             AND gdatu = lv_inv.
    IF sy-subrc = 0 AND ls_tcurf-ffact = cs_item-ffact AND ls_tcurf-tfact = cs_item-tfact.
      cs_item-fac_done = abap_true.
      add_msg( EXPORTING iv_text = 'Factor creado y verificado en TCURF.'
               CHANGING  cv_msg  = cs_item-message ).
    ELSE.
      cs_item-status = gc_st_fail.
      CONCATENATE 'No se creó el factor (SM30):' lv_text INTO lv_text SEPARATED BY space.
      add_msg( EXPORTING iv_text = lv_text CHANGING cv_msg = cs_item-message ).
    ENDIF.
  ENDMETHOD.                    "create_factor

*----------------------------------------------------------------------*
* CALL TRANSACTION SM30 con los datos de mt_bdc. Devuelve el código de
* retorno y TODOS los mensajes recogidos (de cualquier tipo, con la
* pantalla donde se emitieron). Solo se muestran si la relectura de
* TCURC/TCURF indica que el alta no se hizo: la verdad es la relectura.
* (v1.1 filtraba E/A/W/X y perdía el aviso S 00 344 "no hay datos de
* batch input para la dynpro", que es el típico cuando aparece una
* pantalla no prevista.)
*----------------------------------------------------------------------*
  METHOD call_sm30.
    DATA: lt_msg  TYPE STANDARD TABLE OF bdcmsgcoll,
          ls_msg  TYPE bdcmsgcoll,
          ls_opt  TYPE ctu_params,
          lv_rc   TYPE i,
          lv_s1   TYPE string,
          lv_txt  TYPE string.

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
* Conteos, log y ALV
*======================================================================*
  METHOD count_status.
    DATA ls_item TYPE ty_item.

    CLEAR: mv_n_total, mv_n_ok, mv_n_noth, mv_n_rej, mv_n_warn,
           mv_n_done, mv_n_fail, mv_n_cur, mv_n_fac.
    LOOP AT mt_items INTO ls_item.
      mv_n_total = mv_n_total + 1.
      CASE ls_item-status.
        WHEN gc_st_ok.
          mv_n_ok = mv_n_ok + 1.
          IF ls_item-warning = abap_true.
            mv_n_warn = mv_n_warn + 1.
          ENDIF.
          IF ls_item-cur_new = abap_true.
            mv_n_cur = mv_n_cur + 1.
          ENDIF.
          IF ls_item-fac_new = abap_true.
            mv_n_fac = mv_n_fac + 1.
          ENDIF.
        WHEN gc_st_noth.
          mv_n_noth = mv_n_noth + 1.
        WHEN gc_st_rej.
          mv_n_rej = mv_n_rej + 1.
        WHEN gc_st_done.
          mv_n_done = mv_n_done + 1.
          IF ls_item-cur_done = abap_true.
            mv_n_cur = mv_n_cur + 1.
          ENDIF.
          IF ls_item-fac_done = abap_true.
            mv_n_fac = mv_n_fac + 1.
          ENDIF.
        WHEN gc_st_fail OR gc_st_skip.
          mv_n_fail = mv_n_fail + 1.
      ENDCASE.
    ENDLOOP.
  ENDMETHOD.                    "count_status

  METHOD build_output.
    DATA: ls_out  TYPE ty_out,
          ls_item TYPE ty_item,
          lv_txt  TYPE string,
          lv_s1   TYPE string,
          lv_s2   TYPE string,
          lv_s3   TYPE string,
          lv_s4   TYPE string,
          lv_s5   TYPE string.

    CLEAR mt_out.
    CLEAR ls_out.
    ls_out-icon   = icon_information.
    ls_out-estado = 'RESUMEN'.
    CONCATENATE 'Archivo:' p_file INTO ls_out-mensaje SEPARATED BY space.
    APPEND ls_out TO mt_out.
    IF p_real = abap_true.
      CONCATENATE 'Modo: EJECUCIÓN REAL - orden' p_trkorr INTO ls_out-mensaje SEPARATED BY space.
    ELSE.
      ls_out-mensaje = 'Modo: SIMULACIÓN (no se modificó SAP)'.
    ENDIF.
    APPEND ls_out TO mt_out.
    lv_s1 = fmt_int( mv_n_total ).
    lv_s2 = fmt_int( mv_n_ok ).
    lv_s3 = fmt_int( mv_n_noth ).
    lv_s4 = fmt_int( mv_n_rej ).
    lv_s5 = fmt_int( mv_n_warn ).
    CONCATENATE 'Líneas:' lv_s1 '| Para crear:' lv_s2 '(con advertencia:' lv_s5 ')'
                '| Ya existentes:' lv_s3 '| Rechazadas:' lv_s4
           INTO lv_txt SEPARATED BY space.
    ls_out-mensaje = lv_txt.
    APPEND ls_out TO mt_out.
    CONCATENATE 'Resultado:' mv_result INTO ls_out-mensaje SEPARATED BY space.
    APPEND ls_out TO mt_out.

    LOOP AT mt_items INTO ls_item.
      CLEAR ls_out.
      CASE ls_item-status.
        WHEN gc_st_ok.
          IF ls_item-warning = abap_true.
            ls_out-icon   = icon_yellow_light.
            ls_out-estado = 'ADVERTENCIA'.
          ELSE.
            ls_out-icon   = icon_green_light.
            ls_out-estado = 'PARA CREAR'.
          ENDIF.
        WHEN gc_st_noth.
          ls_out-icon   = icon_light_out.
          ls_out-estado = 'YA EXISTE'.
        WHEN gc_st_rej.
          ls_out-icon   = icon_red_light.
          ls_out-estado = 'RECHAZADO'.
        WHEN gc_st_done.
          ls_out-icon   = icon_okay.
          ls_out-estado = 'CREADO'.
        WHEN gc_st_fail.
          ls_out-icon   = icon_cancel.
          ls_out-estado = 'ERROR'.
        WHEN gc_st_skip.
          ls_out-icon   = icon_cancel.
          ls_out-estado = 'NO PROCESADO'.
      ENDCASE.
      ls_out-linea     = ls_item-line.
      ls_out-moneda    = ls_item-waers.
      ls_out-iso       = ls_item-isocd.
      ls_out-texto     = ls_item-ltext.
      ls_out-tipo      = ls_item-kurst.
      ls_out-a_moneda  = ls_item-tcurr.
      ls_out-fecha     = ls_item-valid_from.
      ls_out-factor_de = ls_item-ffact.
      ls_out-factor_a  = ls_item-tfact.
      IF ls_item-cur_done = abap_true.
        ls_out-accion_m = 'CREADA'.
      ELSEIF ls_item-cur_new = abap_true.
        ls_out-accion_m = 'CREAR'.
      ELSEIF ls_item-status <> gc_st_rej.
        ls_out-accion_m = 'EXISTE'.
      ENDIF.
      IF ls_item-fac_done = abap_true.
        ls_out-accion_f = 'CREADO'.
      ELSEIF ls_item-fac_new = abap_true.
        ls_out-accion_f = 'CREAR'.
      ELSEIF ls_item-status <> gc_st_rej.
        ls_out-accion_f = 'EXISTE'.
      ENDIF.
      ls_out-mensaje = ls_item-message.
      APPEND ls_out TO mt_out.
    ENDLOOP.
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

    set_col( io_cols = lo_cols iv_name = 'ICON'      iv_long = 'Semáforo'
             iv_med = 'Semáforo'      iv_short = 'Sem.' ).
    set_col( io_cols = lo_cols iv_name = 'ESTADO'    iv_long = 'Estado'
             iv_med = 'Estado'        iv_short = 'Estado' ).
    set_col( io_cols = lo_cols iv_name = 'LINEA'     iv_long = 'Línea del CSV'
             iv_med = 'Línea CSV'     iv_short = 'Línea' ).
    set_col( io_cols = lo_cols iv_name = 'MONEDA'    iv_long = 'Moneda'
             iv_med = 'Moneda'        iv_short = 'Moneda' ).
    set_col( io_cols = lo_cols iv_name = 'ACCION_M'  iv_long = 'Acción moneda (OY03)'
             iv_med = 'Acción moneda' iv_short = 'Acc.mon.' ).
    set_col( io_cols = lo_cols iv_name = 'ISO'       iv_long = 'Código ISO'
             iv_med = 'ISO'           iv_short = 'ISO' ).
    set_col( io_cols = lo_cols iv_name = 'TEXTO'     iv_long = 'Texto largo'
             iv_med = 'Texto'         iv_short = 'Texto' ).
    set_col( io_cols = lo_cols iv_name = 'TIPO'      iv_long = 'Tipo de cotización'
             iv_med = 'Tipo cotiz.'   iv_short = 'Tipo' ).
    set_col( io_cols = lo_cols iv_name = 'A_MONEDA'  iv_long = 'Moneda destino'
             iv_med = 'Moneda destino' iv_short = 'A' ).
    set_col( io_cols = lo_cols iv_name = 'FECHA'     iv_long = 'Válido desde'
             iv_med = 'Válido desde'  iv_short = 'Fecha' ).
    set_col( io_cols = lo_cols iv_name = 'FACTOR_DE' iv_long = 'Factor "de"'
             iv_med = 'Factor de'     iv_short = 'Fact.de' ).
    set_col( io_cols = lo_cols iv_name = 'FACTOR_A'  iv_long = 'Factor "a"'
             iv_med = 'Factor a'      iv_short = 'Fact.a' ).
    set_col( io_cols = lo_cols iv_name = 'ACCION_F'  iv_long = 'Acción factor (OBBS)'
             iv_med = 'Acción factor' iv_short = 'Acc.fac.' ).
    set_col( io_cols = lo_cols iv_name = 'MENSAJE'   iv_long = 'Mensaje'
             iv_med = 'Mensaje'       iv_short = 'Mensaje' ).

    TRY.
        lo_colt ?= lo_cols->get_column( 'ICON' ).
        lo_colt->set_icon( if_salv_c_bool_sap=>true ).
      CATCH cx_salv_not_found.
    ENDTRY.

    lo_disp = lo_alv->get_display_settings( ).
    lo_disp->set_striped_pattern( abap_true ).
    IF p_real = abap_true.
      lv_title = 'SAP FX Free - Monedas y factores - EJECUCIÓN REAL'.
    ELSE.
      lv_title = 'SAP FX Free - Monedas y factores - SIMULACIÓN'.
    ENDIF.
    lo_disp->set_list_header( lv_title ).
    lo_alv->display( ).
  ENDMETHOD.                    "display

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
