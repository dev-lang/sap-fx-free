*&---------------------------------------------------------------------*
*& Report ZFX_FREE_HTTP_TEST
*&---------------------------------------------------------------------*
*& SAP FX Free - Prueba de conexión HTTPS a la API del BCRA.
*& Solo lectura: hace un GET y muestra el resultado. No modifica SAP.
*& Compatibilidad: SAP_BASIS 731 (sin sintaxis 7.40+).
*& Versión 1.0 - 24.10.2026
*&---------------------------------------------------------------------*
REPORT zfx_free_http_test.

PARAMETERS: p_url   TYPE string LOWER CASE
                    DEFAULT 'https://api.bcra.gob.ar/estadisticascambiarias/v1.0/Cotizaciones',
            p_ssl   TYPE ssfapplssl DEFAULT 'ANONYM',
            p_proxy TYPE string LOWER CASE,
            p_pport TYPE string,
            p_chars TYPE i DEFAULT 1500.

START-OF-SELECTION.
  PERFORM run.

FORM run.
  DATA: lo_client TYPE REF TO if_http_client,
        lv_code   TYPE i,
        lv_reason TYPE string,
        lv_body   TYPE string,
        lv_len    TYPE i,
        lv_rc     TYPE i,
        lv_msg    TYPE string,
        lv_ctype  TYPE string,
        lv_line   TYPE string,
        lv_off    TYPE i,
        lv_n      TYPE i.

  WRITE: / 'URL:', p_url.
  WRITE: / 'SSL ID:', p_ssl.
  IF p_proxy IS NOT INITIAL.
    WRITE: / 'Proxy:', p_proxy, p_pport.
  ENDIF.
  ULINE.

* 1) Crear el cliente
  cl_http_client=>create_by_url(
    EXPORTING
      url                = p_url
      ssl_id             = p_ssl
      proxy_host         = p_proxy
      proxy_service      = p_pport
    IMPORTING
      client             = lo_client
    EXCEPTIONS
      argument_not_found = 1
      plugin_not_active  = 2
      internal_error     = 3
      OTHERS             = 4 ).
  IF sy-subrc <> 0.
    lv_rc = sy-subrc.
    WRITE: / 'ERROR en create_by_url, sy-subrc =', lv_rc.
    CASE lv_rc.
      WHEN 2.
        WRITE: / 'plugin_not_active: el ICM no tiene activo el plugin HTTPS',
               / '(revisar SMICM > Servicios y parámetros ssl/ssl_lib).'.
      WHEN OTHERS.
        WRITE: / 'Revisar URL y SSL ID.'.
    ENDCASE.
    RETURN.
  ENDIF.

  lo_client->request->set_method( 'GET' ).
  lo_client->request->set_header_field( name  = 'Accept'
                                        value = 'application/json' ).
  lo_client->request->set_header_field( name  = 'User-Agent'
                                        value = 'SAP-FX-Free/0.1 (ABAP)' ).
  lo_client->propertytype_logon_popup = if_http_client=>co_disabled.

* 2) Enviar
  lo_client->send(
    EXCEPTIONS
      http_communication_failure = 1
      http_invalid_state         = 2
      http_processing_failed     = 3
      http_invalid_timeout       = 4
      OTHERS                     = 5 ).
  IF sy-subrc <> 0.
    lv_rc = sy-subrc.
    lo_client->get_last_error( IMPORTING message = lv_msg ).
    WRITE: / 'ERROR en send, sy-subrc =', lv_rc.
    WRITE: / lv_msg.
    lo_client->close( ).
    RETURN.
  ENDIF.

* 3) Recibir
  lo_client->receive(
    EXCEPTIONS
      http_communication_failure = 1
      http_invalid_state         = 2
      http_processing_failed     = 3
      OTHERS                     = 4 ).
  IF sy-subrc <> 0.
    lv_rc = sy-subrc.
    lo_client->get_last_error( IMPORTING message = lv_msg ).
    WRITE: / 'ERROR en receive, sy-subrc =', lv_rc.
    WRITE: / lv_msg.
    WRITE: / 'Si menciona SSL/handshake/certificado: falta importar en STRUST',
           / '(PSE SSL cliente Anónimo) la cadena de certificados del BCRA.'.
    lo_client->close( ).
    RETURN.
  ENDIF.

* 4) Resultado
  lo_client->response->get_status( IMPORTING code   = lv_code
                                             reason = lv_reason ).
  lv_ctype = lo_client->response->get_header_field( 'content-type' ).
  lv_body  = lo_client->response->get_cdata( ).
  lv_len   = strlen( lv_body ).

  WRITE: / 'HTTP:', lv_code, lv_reason.
  WRITE: / 'Content-Type:', lv_ctype.
  WRITE: / 'Largo de la respuesta:', lv_len.
  ULINE.

* Primeros p_chars caracteres, en líneas de 100
  IF lv_len > p_chars.
    lv_len = p_chars.
  ENDIF.
  lv_off = 0.
  WHILE lv_off < lv_len.
    lv_n = lv_len - lv_off.
    IF lv_n > 100.
      lv_n = 100.
    ENDIF.
    lv_line = lv_body+lv_off(lv_n).
    WRITE: / lv_line.
    lv_off = lv_off + lv_n.
  ENDWHILE.

  lo_client->close( ).
ENDFORM.
