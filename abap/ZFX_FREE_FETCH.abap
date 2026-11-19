*&---------------------------------------------------------------------*
*& Report ZFX_FREE_FETCH
*&---------------------------------------------------------------------*
*& SAP FX Free - Descarga directa de cotizaciones del BCRA desde SAP.
*&
*& Hace lo mismo que el script Python sap_fx_free.py, pero en ABAP:
*&  1) GET HTTPS a la API pública del BCRA (estadisticascambiarias).
*&  2) Convierte el JSON al mismo CSV que genera el script.
*&  3) Llama a ZFX_FREE_LOAD (SUBMIT, CSV por memoria ABAP), que hace
*&     todas las validaciones y la carga (o la simulación).
*&
*& Reglas:
*&  - Este programa no escribe en SAP: solo lee TCURF para decidir qué
*&    monedas incluir. La carga la hace siempre ZFX_FREE_LOAD.
*&  - Se incluyen solo las monedas con factores M X->ARS en OBBS vigentes
*&    a la fecha (las mismas que ZFX_FREE_LOAD acepta). Las demás se
*&    informan en el log como excluidas, sin bloquear la carga.
*&  - Requiere en STRUST (SSL cliente anónimo) la raíz ISRG Root X1.
*&
*& Compatibilidad: SAP_BASIS 731 (sin sintaxis 7.40+). El JSON se lee con
*& expresiones regulares (el formato de la API es fijo y simple).
*& Versión 1.0 - 24.10.2026
*& Versión 1.1 - 19.11.2026 (fecha mínima 02.01.1992 desde el include
*&               ZFX_FREE_CONST: antes, la API responde HTTP 400)
*& Versión 1.2 - 19.11.2026 (día sin publicación del BCRA, "fecha":
*&               null: fin normal "sin cotizaciones publicadas")
*& Versión 1.3 - 19.11.2026 (modo job: en fondo, fecha vacía = hoy, sin
*&               popup, errores tipo E para que SM37 marque Cancelado y
*&               mail opcional si falla; control de la fecha devuelta y
*&               timeout HTTP)
*&---------------------------------------------------------------------*
REPORT zfx_free_fetch.

TYPE-POOLS: abap.

INCLUDE zfx_free_const.   " gc_api_min_date (primera fecha de la API)

TYPES: ty_t_string TYPE STANDARD TABLE OF string WITH DEFAULT KEY.

TYPES: BEGIN OF ty_map,
         api TYPE string,
         sap TYPE string,
       END OF ty_map,
       ty_t_map TYPE STANDARD TABLE OF ty_map WITH DEFAULT KEY.

TYPES: BEGIN OF ty_unit,
         api   TYPE string,
         units TYPE i,
       END OF ty_unit,
       ty_t_unit TYPE STANDARD TABLE OF ty_unit WITH DEFAULT KEY.

CONSTANTS:
  gc_url      TYPE string VALUE 'https://api.bcra.gob.ar/estadisticascambiarias/v1.0/Cotizaciones',
  gc_kurst    TYPE tcurf-kurst VALUE 'M',
  gc_tcurr    TYPE tcurf-tcurr VALUE 'ARS',
  gc_status   TYPE string VALUE 'REVIEW_REQUIRED',
  gc_mem_csv  TYPE c LENGTH 20 VALUE 'ZFX_FREE_CSV',
  gc_mem_info TYPE c LENGTH 20 VALUE 'ZFX_FREE_INFO',
  gc_mem_res  TYPE c LENGTH 20 VALUE 'ZFX_FREE_RES',
  gc_timeout  TYPE i VALUE 60.              " segundos (HTTP)

* Modo job activo: p_job marcado y corriendo en fondo
DATA gv_job TYPE abap_bool.

*----------------------------------------------------------------------*
* Pantalla de selección
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b01 WITH FRAME TITLE t_b01.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_fecha FOR FIELD p_fecha.
PARAMETERS p_fecha TYPE d.
SELECTION-SCREEN COMMENT 45(40) c_fech2.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_ssl FOR FIELD p_ssl.
PARAMETERS p_ssl TYPE ssfapplssl DEFAULT 'ANONYM'.
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
SELECTION-SCREEN BEGIN OF LINE.
PARAMETERS p_show AS CHECKBOX.
SELECTION-SCREEN COMMENT 4(70) c_show FOR FIELD p_show.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b03.

SELECTION-SCREEN BEGIN OF BLOCK b04 WITH FRAME TITLE t_b04.
SELECTION-SCREEN BEGIN OF LINE.
PARAMETERS p_job AS CHECKBOX.
SELECTION-SCREEN COMMENT 4(70) c_job FOR FIELD p_job.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 1(31) c_mail FOR FIELD p_mail.
PARAMETERS p_mail TYPE ad_smtpadr LOWER CASE.
SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b04.

INITIALIZATION.
  t_b01   = 'Origen: API del BCRA'.
  t_b02   = 'Modo de ejecución (lo aplica ZFX_FREE_LOAD)'.
  t_b03   = 'Controles'.
  c_fecha = 'Fecha de cotización'.
  c_fech2 = '(vacía = última publicada)'.
  c_ssl   = 'Identidad SSL (STRUST)'.
  c_sim   = 'Simulación: valida y muestra el log, no modifica SAP'.
  c_real  = 'Carga real: crea las cotizaciones (pide confirmación)'.
  c_desv  = 'Variación para advertir (%)'.
  c_acept = 'Acepto las advertencias revisadas (solo carga real)'.
  c_show  = 'Solo mostrar el CSV generado (no llama a ZFX_FREE_LOAD)'.
  t_b04   = 'Job (solo en fondo)'.
  c_job   = 'Modo job: sin popup, fecha vacía = hoy, error = job Cancelado'.
  c_mail  = 'Mail si falla (modo job)'.

AT SELECTION-SCREEN.
  IF p_desv <= 0 OR p_desv > 1000.
    MESSAGE 'El umbral de variación debe estar entre 1 y 1000 %.' TYPE 'E'.
  ENDIF.
  IF p_fecha IS NOT INITIAL AND p_fecha > sy-datlo.
    MESSAGE 'La fecha de cotización no puede ser futura.' TYPE 'E'.
  ENDIF.
  IF p_fecha IS NOT INITIAL AND p_fecha < gc_api_min_date.
    PERFORM error_min_date.
  ENDIF.

START-OF-SELECTION.
  IF p_job = abap_true AND sy-batch = abap_true.
    gv_job = abap_true.
    IF p_fecha IS INITIAL.
      p_fecha = sy-datum.                  " el job carga el día de hoy
    ENDIF.
  ENDIF.
  PERFORM main.

*======================================================================*
* Fecha anterior a la primera que acepta la API: error en pantalla,
* sin hacer el pedido HTTP (el BCRA respondería 400).
*======================================================================*
FORM error_min_date.
  DATA: lv_d   TYPE c LENGTH 10,
        lv_txt TYPE string.

  WRITE gc_api_min_date TO lv_d DD/MM/YYYY.
  CONCATENATE 'La API del BCRA no acepta fechas anteriores al' lv_d
              '(antes del peso no hay cotizaciones).'
         INTO lv_txt SEPARATED BY space.
  MESSAGE lv_txt TYPE 'E'.
ENDFORM.                    "error_min_date

*======================================================================*
* Proceso principal
*======================================================================*
FORM main.
  DATA: lv_url    TYPE string,
        lv_json   TYPE string,
        lv_error  TYPE string,
        lv_csv    TYPE string,
        lv_date   TYPE string,
        lv_n      TYPE i,
        lv_s1     TYPE string,
        lv_label  TYPE rlgrap-filename,
        lt_info   TYPE ty_t_string,
        lv_line   TYPE string,
        lv_nopub  TYPE abap_bool,
        lv_dtxt   TYPE c LENGTH 10,
        ls_pri    TYPE pri_params,
        lv_valid  TYPE c LENGTH 1.

  lv_url = gc_url.
  IF p_fecha IS NOT INITIAL.
    CONCATENATE p_fecha+0(4) '-' p_fecha+4(2) '-' p_fecha+6(2) INTO lv_date.
    CONCATENATE lv_url '?fecha=' lv_date INTO lv_url.
  ENDIF.

* 1) Descarga
  PERFORM http_get USING lv_url CHANGING lv_json lv_error.
  IF lv_error IS NOT INITIAL.
    PERFORM fail USING lv_error.
    RETURN.
  ENDIF.

* 2) JSON -> CSV
  PERFORM json_to_csv USING lv_json lv_url
                      CHANGING lv_csv lt_info lv_n lv_error lv_nopub.
* Día sin publicación (feriado o no hábil): fin normal, nada que cargar
  IF lv_nopub = abap_true.
    IF p_fecha IS INITIAL.
      MESSAGE 'El BCRA no publicó cotizaciones para la última fecha: nada para cargar.'
        TYPE 'S'.
    ELSE.
      WRITE p_fecha TO lv_dtxt DD/MM/YYYY.
      CONCATENATE 'Sin cotizaciones publicadas por el BCRA para el' lv_dtxt
                  '(feriado o día no hábil): nada para cargar.'
             INTO lv_s1 SEPARATED BY space.
      MESSAGE lv_s1 TYPE 'S'.
    ENDIF.
    RETURN.
  ENDIF.
  IF lv_error IS NOT INITIAL.
    PERFORM fail USING lv_error.
    RETURN.
  ENDIF.
  IF lv_n = 0.
    lv_error = 'La respuesta no trajo ninguna moneda habilitada en OBBS: no hay nada para cargar.'.
    PERFORM fail USING lv_error.
    RETURN.
  ENDIF.

* 3a) Solo mostrar
  IF p_show = abap_true.
    lv_s1 = lv_n.
    CONDENSE lv_s1.
    WRITE: / 'URL:', lv_url.
    WRITE: / 'Monedas incluidas:', lv_s1.
    LOOP AT lt_info INTO lv_line.
      WRITE: / lv_line.
    ENDLOOP.
    ULINE.
    PERFORM write_long USING lv_csv.
    RETURN.
  ENDIF.

* 3b) Pasar a ZFX_FREE_LOAD por memoria
  EXPORT csv = lv_csv TO MEMORY ID gc_mem_csv.
  EXPORT info = lt_info TO MEMORY ID gc_mem_info.
  CONCATENATE 'API BCRA' lv_url INTO lv_s1 SEPARATED BY space.
  lv_label = lv_s1.

  FREE MEMORY ID gc_mem_res.              " sin restos de otra corrida
* En modo job, el log de ZFX_FREE_LOAD va a un spool propio (ancho 255);
* si no, en fondo la lista del programa llamado se pierde.
  IF gv_job = abap_true.
    PERFORM job_print_params CHANGING ls_pri lv_valid.
  ENDIF.
  IF gv_job = abap_true AND lv_valid = abap_true.
    SUBMIT zfx_free_load
      WITH p_file  = lv_label
      WITH p_stat  = gc_status
      WITH p_sim   = p_sim
      WITH p_real  = p_real
      WITH p_desv  = p_desv
      WITH p_acept = p_acept
      WITH p_mem   = abap_true
      WITH p_job   = gv_job
      TO SAP-SPOOL SPOOL PARAMETERS ls_pri WITHOUT SPOOL DYNPRO
      AND RETURN.
  ELSE.
    SUBMIT zfx_free_load
      WITH p_file  = lv_label
      WITH p_stat  = gc_status
      WITH p_sim   = p_sim
      WITH p_real  = p_real
      WITH p_desv  = p_desv
      WITH p_acept = p_acept
      WITH p_mem   = abap_true
      WITH p_job   = gv_job
      AND RETURN.
  ENDIF.

  FREE MEMORY ID gc_mem_csv.
  FREE MEMORY ID gc_mem_info.

* 4) Modo job: resultado de ZFX_FREE_LOAD -> job log, y error si falló
  IF gv_job = abap_true.
    PERFORM job_result.
  ENDIF.
  FREE MEMORY ID gc_mem_res.
ENDFORM.

*======================================================================*
* Parámetros de spool para el log de ZFX_FREE_LOAD en modo job: la
* impresora del paso del job (sy-pdest) o LP01, formato X_65_255, sin
* imprimir (queda en SP01 / spool del job).
*======================================================================*
FORM job_print_params CHANGING cs_pri   TYPE pri_params
                               cv_valid TYPE c.
* Variables tipadas: GET_PRINT_PARAMETERS no acepta literales sueltos
* (CALL_FUNCTION_CONFLICT_TYPE en LIST_NAME)
  DATA: lv_dest  TYPE pri_params-pdest,
        lv_lay   TYPE pri_params-paart,
        lv_lins  TYPE pri_params-linsz,
        lv_lname TYPE pri_params-plist,
        lv_imm   TYPE pri_params-primm,
        lv_newid TYPE pri_params-prnew.

  CLEAR: cs_pri, cv_valid.
  lv_dest = sy-pdest.
  IF lv_dest IS INITIAL.
    lv_dest = 'LP01'.
  ENDIF.
  lv_lay   = 'X_65_255'.
  lv_lins  = 255.
  lv_lname = 'ZFX_FREE_LOAD'.
  lv_imm   = space.
  lv_newid = 'X'.
  CALL FUNCTION 'GET_PRINT_PARAMETERS'
    EXPORTING
      destination    = lv_dest
      immediately    = lv_imm
      layout         = lv_lay
      line_size      = lv_lins
      list_name      = lv_lname
      new_list_id    = lv_newid
      no_dialog      = 'X'
    IMPORTING
      out_parameters = cs_pri
      valid          = cv_valid
    EXCEPTIONS
      OTHERS         = 1.
  IF sy-subrc <> 0.
    CLEAR cv_valid.
  ENDIF.
ENDFORM.                    "job_print_params

*======================================================================*
* Error: en modo job manda el mail (si hay dirección) y corta con un
* mensaje tipo E, para que SM37 marque el job como Cancelado. En
* diálogo, mensaje de estado en rojo.
*======================================================================*
FORM fail USING iv_text TYPE string.
  IF gv_job = abap_true.
    PERFORM send_mail USING iv_text.
    MESSAGE iv_text TYPE 'E'.
  ELSE.
    MESSAGE iv_text TYPE 'S' DISPLAY LIKE 'E'.
  ENDIF.
ENDFORM.                    "fail

*======================================================================*
* Resultado de ZFX_FREE_LOAD en modo job: OK o NADA = fin normal;
* cualquier otro (o sin resultado) = error.
*======================================================================*
FORM job_result.
  DATA: lv_code TYPE c LENGTH 5,
        lv_text TYPE string.

  IMPORT code = lv_code text = lv_text FROM MEMORY ID gc_mem_res.
  IF sy-subrc <> 0.
    lv_text = 'ZFX_FREE_LOAD terminó sin informar resultado: revisar el spool del job.'.
    PERFORM fail USING lv_text.
    RETURN.
  ENDIF.
  IF lv_code = 'OK' OR lv_code = 'NADA' OR lv_code = 'SIM'.
    MESSAGE lv_text TYPE 'S'.
  ELSE.
    PERFORM fail USING lv_text.
  ENDIF.
ENDFORM.                    "job_result

*======================================================================*
* Mail por SCOT (CL_BCS) con el error. Si falla el envío, solo queda
* en el job log: el job se cancela igual por el error original.
*======================================================================*
FORM send_mail USING iv_text TYPE string.
  DATA: lo_send  TYPE REF TO cl_bcs,
        lo_doc   TYPE REF TO cl_document_bcs,
        lo_rec   TYPE REF TO if_recipient_bcs,
        lx_bcs   TYPE REF TO cx_bcs,
        lt_text  TYPE bcsy_text,
        ls_text  TYPE soli,
        lv_subj  TYPE so_obj_des,
        lv_date  TYPE c LENGTH 10,
        lv_txt   TYPE string,
        lv_rest  TYPE string.

  IF p_mail IS INITIAL.
    RETURN.
  ENDIF.

  WRITE p_fecha TO lv_date DD/MM/YYYY.
  CONCATENATE 'SAP FX Free: falló la carga del' lv_date
         INTO lv_txt SEPARATED BY space.
  lv_subj = lv_txt.

  CONCATENATE 'Sistema' sy-sysid 'mandante' sy-mandt '- job ZFX_FREE_FETCH.'
         INTO ls_text-line SEPARATED BY space.
  APPEND ls_text TO lt_text.
  CONCATENATE 'Fecha de cotización:' lv_date INTO ls_text-line SEPARATED BY space.
  APPEND ls_text TO lt_text.
  CLEAR ls_text.
  APPEND ls_text TO lt_text.
* El texto del error en líneas de 255 caracteres (SOLI)
  lv_rest = iv_text.
  WHILE lv_rest IS NOT INITIAL.
    IF strlen( lv_rest ) > 255.
      ls_text-line = lv_rest(255).
      lv_rest = lv_rest+255.
    ELSE.
      ls_text-line = lv_rest.
      CLEAR lv_rest.
    ENDIF.
    APPEND ls_text TO lt_text.
  ENDWHILE.
  CLEAR ls_text.
  APPEND ls_text TO lt_text.
  ls_text-line = 'No se cargó ninguna cotización. Detalle en SM37 (log y spool del job).'.
  APPEND ls_text TO lt_text.

  TRY.
      lo_send = cl_bcs=>create_persistent( ).
      lo_doc = cl_document_bcs=>create_document( i_type    = 'RAW'
                                                 i_text    = lt_text
                                                 i_subject = lv_subj ).
      lo_send->set_document( lo_doc ).
      lo_rec = cl_cam_address_bcs=>create_internet_address( p_mail ).
      lo_send->add_recipient( lo_rec ).
      lo_send->set_send_immediately( abap_true ).
      lo_send->send( ).
      COMMIT WORK.
      CONCATENATE 'Mail de error enviado a' p_mail INTO lv_txt SEPARATED BY space.
      MESSAGE lv_txt TYPE 'S'.
    CATCH cx_bcs INTO lx_bcs.
      lv_txt = lx_bcs->get_text( ).
      CONCATENATE 'No se pudo enviar el mail de error:' lv_txt
             INTO lv_txt SEPARATED BY space.
      MESSAGE lv_txt TYPE 'S'.
  ENDTRY.
ENDFORM.                    "send_mail

*======================================================================*
* GET HTTPS
*======================================================================*
FORM http_get USING    iv_url   TYPE string
              CHANGING cv_body  TYPE string
                       cv_error TYPE string.
  DATA: lo_client TYPE REF TO if_http_client,
        lv_code   TYPE i,
        lv_reason TYPE string,
        lv_msg    TYPE string,
        lv_s1     TYPE string.

  CLEAR: cv_body, cv_error.

  cl_http_client=>create_by_url(
    EXPORTING
      url                = iv_url
      ssl_id             = p_ssl
    IMPORTING
      client             = lo_client
    EXCEPTIONS
      argument_not_found = 1
      plugin_not_active  = 2
      internal_error     = 3
      OTHERS             = 4 ).
  IF sy-subrc <> 0.
    lv_s1 = sy-subrc.
    CONCATENATE 'No se pudo crear el cliente HTTP (sy-subrc' lv_s1
                '). Revisar ICM/HTTPS y la identidad SSL.'
           INTO cv_error SEPARATED BY space.
    RETURN.
  ENDIF.

  lo_client->request->set_method( 'GET' ).
  lo_client->request->set_header_field( name  = 'Accept'
                                        value = 'application/json' ).
  lo_client->request->set_header_field( name  = 'User-Agent'
                                        value = 'SAP-FX-Free/1.0 (ABAP)' ).
  lo_client->propertytype_logon_popup = if_http_client=>co_disabled.

  lo_client->send(
    EXPORTING
      timeout                    = gc_timeout
    EXCEPTIONS
      http_communication_failure = 1
      http_invalid_state         = 2
      http_processing_failed     = 3
      http_invalid_timeout       = 4
      OTHERS                     = 5 ).
  IF sy-subrc = 0.
    lo_client->receive(
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        http_processing_failed     = 3
        OTHERS                     = 4 ).
  ENDIF.
  IF sy-subrc <> 0.
    lo_client->get_last_error( IMPORTING message = lv_msg ).
    CONCATENATE 'Error de comunicación con el BCRA:' lv_msg
                '(si es SSL: revisar STRUST, SSL cliente anónimo, raíz ISRG Root X1).'
           INTO cv_error SEPARATED BY space.
    lo_client->close( ).
    RETURN.
  ENDIF.

  lo_client->response->get_status( IMPORTING code   = lv_code
                                             reason = lv_reason ).
  cv_body = lo_client->response->get_cdata( ).
  lo_client->close( ).

  IF lv_code <> 200.
    lv_s1 = lv_code.
    CONDENSE lv_s1.
    CONCATENATE 'El BCRA respondió HTTP' lv_s1 lv_reason
           INTO cv_error SEPARATED BY space.
    RETURN.
  ENDIF.
  IF cv_body IS INITIAL.
    cv_error = 'El BCRA respondió sin contenido.'.
  ENDIF.
ENDFORM.

*======================================================================*
* JSON de la API -> CSV con el contrato de ZFX_FREE_LOAD
* Formato esperado:
* {"status":200,"results":{"fecha":"AAAA-MM-DD","detalle":[
*   {"codigoMoneda":"USD","descripcion":"...","tipoPase":1.0,
*    "tipoCotizacion":1529.50000000}, ...]}}
*======================================================================*
FORM json_to_csv USING    iv_json  TYPE string
                          iv_url   TYPE string
                 CHANGING cv_csv   TYPE string
                          ct_info  TYPE ty_t_string
                          cv_count TYPE i
                          cv_error TYPE string
                          cv_nopub TYPE abap_bool.
  DATA: lv_fecha  TYPE string,
        lv_datum  TYPE d,
        lv_inv    TYPE tcurf-gdatu,
        lv_det    TYPE string,
        lt_res    TYPE match_result_tab,
        ls_res    TYPE match_result,
        lv_obj    TYPE string,
        lv_api    TYPE string,
        lv_code   TYPE string,
        lv_desc   TYPE string,
        lv_rate   TYPE string,
        lv_field  TYPE string,
        lv_p      TYPE p LENGTH 16 DECIMALS 9,
        lv_units  TYPE i,
        lv_rtxt   TYPE string,
        lv_kurst  TYPE tcurf-kurst,
        lv_waers  TYPE tcurf-fcurr,
        lv_len    TYPE i,
        lv_crlf   TYPE string,
        lv_txt    TYPE string,
        lt_done   TYPE ty_t_string,
        lt_map    TYPE ty_t_map,
        ls_map    TYPE ty_map,
        lt_unit   TYPE ty_t_unit,
        ls_unit   TYPE ty_unit,
        lv_off    TYPE i,
        lv_dlen   TYPE i,
        lv_moff   TYPE i,
        lv_mlen   TYPE i.

  CLEAR: cv_csv, ct_info, cv_count, cv_error, cv_nopub.
  lv_crlf = cl_abap_char_utilities=>cr_lf.

* Códigos del BCRA distintos de los de SAP (igual que config.json)
  ls_map-api = 'MXP'. ls_map-sap = 'MXN'. APPEND ls_map TO lt_map.
  ls_map-api = 'VEB'. ls_map-sap = 'VES'. APPEND ls_map TO lt_map.
* Unidades en que el BCRA publica la cotización (VND cada 1.000)
  ls_unit-api = 'VND'. ls_unit-units = 1000. APPEND ls_unit TO lt_unit.

* Estado
  FIND REGEX '"status"\s*:\s*200[,}]' IN iv_json.
  IF sy-subrc <> 0.
    lv_len = strlen( iv_json ).
    IF lv_len > 200.
      lv_len = 200.
    ENDIF.
    lv_txt = iv_json(lv_len).
    CONCATENATE 'Respuesta inesperada del BCRA:' lv_txt
           INTO cv_error SEPARATED BY space.
    RETURN.
  ENDIF.

* Fecha
  FIND REGEX '"fecha"\s*:\s*"(\d{4}-\d{2}-\d{2})"' IN iv_json
       SUBMATCHES lv_fecha.
  IF sy-subrc <> 0.
*   Día sin publicación: la API responde 200 con "fecha": null y
*   "detalle" vacío (pasó el 06.11, 09.11 y 10.11.2026)
    FIND REGEX '"fecha"\s*:\s*null' IN iv_json.
    IF sy-subrc = 0.
      cv_nopub = abap_true.
      RETURN.
    ENDIF.
    cv_error = 'La respuesta del BCRA no trae la fecha de cotización.'.
    RETURN.
  ENDIF.
  CONCATENATE lv_fecha+0(4) lv_fecha+5(2) lv_fecha+8(2) INTO lv_datum.
* La API tiene que devolver la fecha pedida
  IF p_fecha IS NOT INITIAL AND lv_datum <> p_fecha.
    CONCATENATE 'La API del BCRA devolvió la cotización del' lv_fecha
                'en vez de la fecha pedida.'
           INTO cv_error SEPARATED BY space.
    RETURN.
  ENDIF.
  lv_inv = lv_datum.
  TRANSLATE lv_inv USING '09182736455463728190'.

* Bloque "detalle": [ ... ]
  FIND REGEX '"detalle"\s*:\s*\[' IN iv_json
       MATCH OFFSET lv_off MATCH LENGTH lv_dlen.
  IF sy-subrc <> 0.
    cv_error = 'La respuesta del BCRA no trae el detalle de cotizaciones.'.
    RETURN.
  ENDIF.
  lv_off = lv_off + lv_dlen.
  lv_det = iv_json+lv_off.

* Cabecera CSV (mismo contrato que el script Python)
  CONCATENATE 'currency,description,rate_type,from_currency,to_currency,'
              'valid_from,rate,source,source_url,source_date,source_field,status'
         INTO cv_csv.
  CONCATENATE cv_csv lv_crlf INTO cv_csv.

* Un objeto por moneda (sin objetos anidados)
  FIND ALL OCCURRENCES OF REGEX '\{[^{}]*\}' IN lv_det RESULTS lt_res.
  LOOP AT lt_res INTO ls_res.
    lv_moff = ls_res-offset.
    lv_mlen = ls_res-length.
    lv_obj  = lv_det+lv_moff(lv_mlen).
    CLEAR: lv_api, lv_desc, lv_rate.
    FIND REGEX '"codigoMoneda"\s*:\s*"([^"]*)"' IN lv_obj SUBMATCHES lv_api.
    FIND REGEX '"descripcion"\s*:\s*"([^"]*)"' IN lv_obj SUBMATCHES lv_desc.
    FIND REGEX '"tipoCotizacion"\s*:\s*(-?\d+(\.\d+)?)' IN lv_obj SUBMATCHES lv_rate.
    CONDENSE: lv_api, lv_desc.
    TRANSLATE lv_api TO UPPER CASE.
    IF lv_api IS INITIAL.
      CONTINUE.
    ENDIF.

*   Código SAP
    lv_code = lv_api.
    READ TABLE lt_map INTO ls_map WITH KEY api = lv_api.
    IF sy-subrc = 0.
      lv_code = ls_map-sap.
    ENDIF.
    IF lv_code = gc_tcurr.
      CONTINUE.                                " moneda destino
    ENDIF.

*   Cotización > 0
    CLEAR lv_p.
    IF lv_rate IS NOT INITIAL.
      TRY.
          lv_p = lv_rate.
        CATCH cx_sy_conversion_no_number cx_sy_conversion_overflow.
          CLEAR lv_p.
      ENDTRY.
    ENDIF.
    IF lv_p <= 0.
      CONCATENATE lv_code 'excluida: sin cotización en la respuesta.'
             INTO lv_txt SEPARATED BY space.
      APPEND lv_txt TO ct_info.
      CONTINUE.
    ENDIF.

*   Duplicados en la respuesta
    READ TABLE lt_done TRANSPORTING NO FIELDS WITH KEY table_line = lv_code.
    IF sy-subrc = 0.
      CONCATENATE lv_code 'aparece más de una vez en la respuesta: se usa la primera.'
             INTO lv_txt SEPARATED BY space.
      APPEND lv_txt TO ct_info.
      CONTINUE.
    ENDIF.

*   Habilitada en OBBS: factores M X->ARS vigentes a la fecha
    lv_len = strlen( lv_code ).
    IF lv_len > 5.
      CONCATENATE lv_code 'excluida: código de más de 5 caracteres.'
             INTO lv_txt SEPARATED BY space.
      APPEND lv_txt TO ct_info.
      CONTINUE.
    ENDIF.
    lv_waers = lv_code.
    CLEAR lv_kurst.
    SELECT SINGLE kurst FROM tcurf INTO lv_kurst
           WHERE kurst = gc_kurst
             AND fcurr = lv_waers
             AND tcurr = gc_tcurr
             AND gdatu >= lv_inv.
    IF sy-subrc <> 0.
      CONCATENATE lv_code 'excluida: sin factores M->ARS en OBBS (alta con ZFX_FREE_SETUP).'
             INTO lv_txt SEPARATED BY space.
      APPEND lv_txt TO ct_info.
      CONTINUE.
    ENDIF.

*   Unidades del BCRA -> 1 unidad, máximo 9 decimales
    READ TABLE lt_unit INTO ls_unit WITH KEY api = lv_api.
    IF sy-subrc = 0 AND ls_unit-units > 1.
      lv_units = ls_unit-units.
      lv_p = lv_p / lv_units.
    ENDIF.
    PERFORM num_text USING lv_p CHANGING lv_rtxt.

    lv_field = 'tipoCotizacion'.
    IF lv_api <> lv_code.
      CONCATENATE 'tipoCotizacion (' lv_api ')' INTO lv_field.
    ENDIF.
    REPLACE ALL OCCURRENCES OF '"' IN lv_desc WITH '""'.

    CONCATENATE lv_code ',"' lv_desc '",M,' lv_code ',ARS,'
                lv_fecha ',' lv_rtxt ',BCRA,' iv_url ','
                lv_fecha ',' lv_field ',' gc_status lv_crlf
           INTO lv_txt.
    CONCATENATE cv_csv lv_txt INTO cv_csv.
    APPEND lv_code TO lt_done.
    cv_count = cv_count + 1.
  ENDLOOP.
ENDFORM.

*======================================================================*
* Número -> texto con punto decimal, sin ceros finales (máx. 9 dec.)
*======================================================================*
FORM num_text USING iv_p TYPE p CHANGING cv_txt TYPE string.
  DATA lv_c TYPE c LENGTH 40.
  lv_c = iv_p.                    " conversión p -> c usa punto decimal
  CONDENSE lv_c NO-GAPS.
  cv_txt = lv_c.
  IF cv_txt CS '.'.
    SHIFT cv_txt RIGHT DELETING TRAILING '0'.
    SHIFT cv_txt RIGHT DELETING TRAILING '.'.
    CONDENSE cv_txt NO-GAPS.
  ENDIF.
ENDFORM.

*======================================================================*
* Muestra un texto largo partiendo por saltos de línea
*======================================================================*
FORM write_long USING iv_text TYPE string.
  DATA: lt_lines TYPE ty_t_string,
        lv_line  TYPE string,
        lv_crlf  TYPE c LENGTH 2.
  lv_crlf = cl_abap_char_utilities=>cr_lf.
  SPLIT iv_text AT lv_crlf INTO TABLE lt_lines.
  LOOP AT lt_lines INTO lv_line.
    WRITE: / lv_line.
  ENDLOOP.
ENDFORM.
