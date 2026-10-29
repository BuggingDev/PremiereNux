/* Windows.Data.Json.JsonObject for Premiere Pro under Wine.
 *
 * Wine's windows.web.dll creates JsonObject instances that only implement IJsonObject. Premiere Pro 2024
 * (24.4) builds a JSON object with SetNamedValue and then asks it for IMap<HSTRING, IJsonValue>; the
 * E_NOINTERFACE that Wine returns ends in an access violation and a window without content. This DLL
 * activates the same class with the interfaces a real Windows JsonObject has: IJsonObject, IJsonValue,
 * IMap<HSTRING, IJsonValue> and IIterable<IKeyValuePair<HSTRING, IJsonValue>>.
 *
 * Derived from dlls/windows.web/json_object.c of Wine.
 * Copyright (C) 2024 Mohamad Al-Jaf
 * Copyright (C) 2026 Olivia Ryan
 * Copyright (C) 2026 PremiereNux contributors
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#define COBJMACROS
#define INITGUID
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <winstring.h>
#include <activation.h>
#include <roapi.h>

#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Foundation_Collections
#include <windows.foundation.h>
#define WIDL_using_Windows_Data_Json
#include <windows.data.json.h>

#define CLASS_JSON_OBJECT L"Windows.Data.Json.JsonObject"
#define CLASS_PROPERTY_SET L"Windows.Foundation.Collections.PropertySet"

#ifndef E_ILLEGAL_METHOD_CALL
#define E_ILLEGAL_METHOD_CALL ((HRESULT)0x8000000EL)
#endif
#ifndef WEB_E_JSON_VALUE_NOT_FOUND
#define WEB_E_JSON_VALUE_NOT_FOUND ((HRESULT)0x83750009L)
#endif

/* MinGW's interface structs hold a plain (non-const) vtable pointer */
#define VTBL( v ) ((void *)(v))

/* PRNUX_JSON_LOG=1 in the environment: every call is appended to C:\prnux_json.log */
static void trace( const char *fmt, ... )
{
    static int enabled = -1;
    char line[512];
    va_list args;
    HANDLE file;
    DWORD written;
    int len;

    if (enabled < 0) enabled = GetEnvironmentVariableA( "PRNUX_JSON_LOG", line, 8 ) > 0;
    if (!enabled) return;
    va_start( args, fmt );
    len = vsnprintf( line, sizeof(line) - 2, fmt, args );
    va_end( args );
    if (len < 0) return;
    if (len > (int)sizeof(line) - 3) len = sizeof(line) - 3;
    line[len++] = '\r';
    line[len++] = '\n';
    file = CreateFileA( "C:\\prnux_json.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile( file, line, len, &written, NULL );
    CloseHandle( file );
}

static const char *guid_str( REFIID iid )
{
    static char buf[4][40];
    static int n;
    char *s = buf[n++ & 3];
    snprintf( s, 40, "{%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}", iid->Data1, iid->Data2, iid->Data3,
              iid->Data4[0], iid->Data4[1], iid->Data4[2], iid->Data4[3], iid->Data4[4], iid->Data4[5],
              iid->Data4[6], iid->Data4[7] );
    return s;
}

struct json_object
{
    IJsonObject IJsonObject_iface;
    IJsonValue IJsonValue_iface;
    IMap_HSTRING_IJsonValue IMap_iface;
    IIterable_IKeyValuePair_HSTRING_IJsonValue IIterable_iface;
    LONG ref;
    IMap_HSTRING_IInspectable *members;
};

static HRESULT object_query( struct json_object *impl, REFIID iid, void **out )
{
    trace( "QueryInterface %s", guid_str( iid ) );

    if (IsEqualGUID( iid, &IID_IUnknown ) ||
        IsEqualGUID( iid, &IID_IInspectable ) ||
        IsEqualGUID( iid, &IID_IAgileObject ) ||
        IsEqualGUID( iid, &IID_IJsonObject ))
        *out = &impl->IJsonObject_iface;
    else if (IsEqualGUID( iid, &IID_IJsonValue ))
        *out = &impl->IJsonValue_iface;
    else if (IsEqualGUID( iid, &IID_IMap_HSTRING_IJsonValue ))
        *out = &impl->IMap_iface;
    else if (IsEqualGUID( iid, &IID_IIterable_IKeyValuePair_HSTRING_IJsonValue ))
        *out = &impl->IIterable_iface;
    else
    {
        trace( "  not implemented" );
        *out = NULL;
        return E_NOINTERFACE;
    }
    InterlockedIncrement( &impl->ref );
    return S_OK;
}

static ULONG object_release( struct json_object *impl )
{
    ULONG ref = InterlockedDecrement( &impl->ref );
    if (!ref)
    {
        IMap_HSTRING_IInspectable_Release( impl->members );
        free( impl );
    }
    return ref;
}

static HRESULT object_get_iids( ULONG *count, IID **iids )
{
    static const IID *const list[] =
    {
        &IID_IJsonObject, &IID_IJsonValue, &IID_IMap_HSTRING_IJsonValue,
        &IID_IIterable_IKeyValuePair_HSTRING_IJsonValue,
    };
    IID *out;
    ULONG i;

    if (!(out = CoTaskMemAlloc( sizeof(list) ))) return E_OUTOFMEMORY;
    for (i = 0; i < ARRAYSIZE(list); i++) out[i] = *list[i];
    *count = ARRAYSIZE(list);
    *iids = out;
    return S_OK;
}

static HRESULT object_class_name( HSTRING *name )
{
    return WindowsCreateString( CLASS_JSON_OBJECT, ARRAYSIZE(CLASS_JSON_OBJECT) - 1, name );
}

#define DEFINE_INSPECTABLE( pfx, itype, member )                                                    \
    static inline struct json_object *pfx##_impl( itype *iface )                                    \
    {                                                                                               \
        return CONTAINING_RECORD( iface, struct json_object, member );                              \
    }                                                                                               \
    static HRESULT WINAPI pfx##_QueryInterface( itype *iface, REFIID iid, void **out )              \
    {                                                                                               \
        return object_query( pfx##_impl( iface ), iid, out );                                      \
    }                                                                                               \
    static ULONG WINAPI pfx##_AddRef( itype *iface )                                                \
    {                                                                                               \
        return InterlockedIncrement( &pfx##_impl( iface )->ref );                                   \
    }                                                                                               \
    static ULONG WINAPI pfx##_Release( itype *iface )                                               \
    {                                                                                               \
        return object_release( pfx##_impl( iface ) );                                               \
    }                                                                                               \
    static HRESULT WINAPI pfx##_GetIids( itype *iface, ULONG *count, IID **iids )                   \
    {                                                                                               \
        return object_get_iids( count, iids );                                                      \
    }                                                                                               \
    static HRESULT WINAPI pfx##_GetRuntimeClassName( itype *iface, HSTRING *name )                  \
    {                                                                                               \
        return object_class_name( name );                                                           \
    }                                                                                               \
    static HRESULT WINAPI pfx##_GetTrustLevel( itype *iface, TrustLevel *level )                    \
    {                                                                                               \
        *level = BaseTrust;                                                                         \
        return S_OK;                                                                                \
    }

/* ---- IJsonObject ---- */

DEFINE_INSPECTABLE( object, IJsonObject, IJsonObject_iface )

static HRESULT WINAPI object_GetNamedValue( IJsonObject *iface, HSTRING name, IJsonValue **value )
{
    struct json_object *impl = object_impl( iface );
    boolean exists;
    HRESULT hr;

    trace( "GetNamedValue %ls", WindowsGetStringRawBuffer( name, NULL ) );
    if (!value) return E_POINTER;
    hr = IMap_HSTRING_IInspectable_HasKey( impl->members, name, &exists );
    if (FAILED(hr) || !exists) return WEB_E_JSON_VALUE_NOT_FOUND;
    return IMap_HSTRING_IInspectable_Lookup( impl->members, name, (IInspectable **)value );
}

static HRESULT WINAPI object_SetNamedValue( IJsonObject *iface, HSTRING name, IJsonValue *value )
{
    struct json_object *impl = object_impl( iface );
    boolean replaced;

    trace( "SetNamedValue %ls", WindowsGetStringRawBuffer( name, NULL ) );
    return IMap_HSTRING_IInspectable_Insert( impl->members, name, (IInspectable *)value, &replaced );
}

/* the typed getters: look the value up, check its type, and use it before the reference is dropped */
static HRESULT named_typed( IJsonObject *iface, HSTRING name, JsonValueType want, IJsonValue **out )
{
    JsonValueType type;
    HRESULT hr;

    if (FAILED(hr = object_GetNamedValue( iface, name, out ))) return hr;
    IJsonValue_get_ValueType( *out, &type );
    if (type != want)
    {
        IJsonValue_Release( *out );
        *out = NULL;
        return E_ILLEGAL_METHOD_CALL;
    }
    return S_OK;
}

static HRESULT WINAPI object_GetNamedObject( IJsonObject *iface, HSTRING name, IJsonObject **value )
{
    IJsonValue *v;
    HRESULT hr;

    if (!value) return E_POINTER;
    if (FAILED(hr = named_typed( iface, name, JsonValueType_Object, &v ))) return hr;
    hr = IJsonValue_GetObject( v, value );
    IJsonValue_Release( v );
    return hr;
}

static HRESULT WINAPI object_GetNamedArray( IJsonObject *iface, HSTRING name, IJsonArray **value )
{
    IJsonValue *v;
    HRESULT hr;

    if (!value) return E_POINTER;
    if (FAILED(hr = named_typed( iface, name, JsonValueType_Array, &v ))) return hr;
    hr = IJsonValue_GetArray( v, value );
    IJsonValue_Release( v );
    return hr;
}

static HRESULT WINAPI object_GetNamedString( IJsonObject *iface, HSTRING name, HSTRING *value )
{
    IJsonValue *v;
    HRESULT hr;

    if (!value) return E_POINTER;
    if (FAILED(hr = named_typed( iface, name, JsonValueType_String, &v ))) return hr;
    hr = IJsonValue_GetString( v, value );
    IJsonValue_Release( v );
    return hr;
}

static HRESULT WINAPI object_GetNamedNumber( IJsonObject *iface, HSTRING name, DOUBLE *value )
{
    IJsonValue *v;
    HRESULT hr;

    if (!value) return E_POINTER;
    if (FAILED(hr = named_typed( iface, name, JsonValueType_Number, &v ))) return hr;
    hr = IJsonValue_GetNumber( v, value );
    IJsonValue_Release( v );
    return hr;
}

static HRESULT WINAPI object_GetNamedBoolean( IJsonObject *iface, HSTRING name, boolean *value )
{
    IJsonValue *v;
    HRESULT hr;

    if (!value) return E_POINTER;
    if (FAILED(hr = named_typed( iface, name, JsonValueType_Boolean, &v ))) return hr;
    hr = IJsonValue_GetBoolean( v, value );
    IJsonValue_Release( v );
    return hr;
}

static const IJsonObjectVtbl object_vtbl =
{
    .QueryInterface = object_QueryInterface,
    .AddRef = object_AddRef,
    .Release = object_Release,
    .GetIids = object_GetIids,
    .GetRuntimeClassName = object_GetRuntimeClassName,
    .GetTrustLevel = object_GetTrustLevel,
    .GetNamedValue = object_GetNamedValue,
    .SetNamedValue = object_SetNamedValue,
    .GetNamedObject = object_GetNamedObject,
    .GetNamedArray = object_GetNamedArray,
    .GetNamedString = object_GetNamedString,
    .GetNamedNumber = object_GetNamedNumber,
    .GetNamedBoolean = object_GetNamedBoolean,
};

/* ---- IJsonValue (a JsonObject is a JsonValue of type Object) ---- */

DEFINE_INSPECTABLE( value, IJsonValue, IJsonValue_iface )

static HRESULT WINAPI value_get_ValueType( IJsonValue *iface, JsonValueType *type )
{
    if (!type) return E_POINTER;
    *type = JsonValueType_Object;
    return S_OK;
}

static HRESULT append( WCHAR **buf, SIZE_T *len, SIZE_T *cap, const WCHAR *text, SIZE_T n )
{
    if (*len + n + 1 > *cap)
    {
        SIZE_T ncap = (*cap ? *cap * 2 : 256) + n;
        WCHAR *p = realloc( *buf, ncap * sizeof(WCHAR) );
        if (!p) return E_OUTOFMEMORY;
        *buf = p;
        *cap = ncap;
    }
    memcpy( *buf + *len, text, n * sizeof(WCHAR) );
    *len += n;
    (*buf)[*len] = 0;
    return S_OK;
}

static HRESULT append_json_string( WCHAR **buf, SIZE_T *len, SIZE_T *cap, const WCHAR *s )
{
    HRESULT hr;

    if (FAILED(hr = append( buf, len, cap, L"\"", 1 ))) return hr;
    for (; *s; s++)
    {
        WCHAR esc[8];
        if (*s == '"' || *s == '\\')
        {
            esc[0] = '\\';
            esc[1] = *s;
            hr = append( buf, len, cap, esc, 2 );
        }
        else if (*s < 0x20)
        {
            swprintf( esc, ARRAYSIZE(esc), L"\\u%04x", *s );
            hr = append( buf, len, cap, esc, 6 );
        }
        else hr = append( buf, len, cap, s, 1 );
        if (FAILED(hr)) return hr;
    }
    return append( buf, len, cap, L"\"", 1 );
}

/* JSON text of a value. Wine's own values may not implement Stringify, so the typed getters are the fallback. */
static HRESULT append_value( WCHAR **buf, SIZE_T *len, SIZE_T *cap, IJsonValue *json )
{
    JsonValueType type = JsonValueType_Null;
    HSTRING text;
    HRESULT hr;

    if (SUCCEEDED(IJsonValue_Stringify( json, &text )))
    {
        UINT32 n;
        const WCHAR *raw = WindowsGetStringRawBuffer( text, &n );
        if (n)
        {
            hr = append( buf, len, cap, raw, n );
            WindowsDeleteString( text );
            return hr;
        }
        WindowsDeleteString( text );
    }

    IJsonValue_get_ValueType( json, &type );
    switch (type)
    {
    case JsonValueType_Boolean:
    {
        boolean b = 0;
        IJsonValue_GetBoolean( json, &b );
        return b ? append( buf, len, cap, L"true", 4 ) : append( buf, len, cap, L"false", 5 );
    }
    case JsonValueType_Number:
    {
        WCHAR num[40];
        DOUBLE d = 0;
        IJsonValue_GetNumber( json, &d );
        swprintf( num, ARRAYSIZE(num), L"%.17g", d );
        return append( buf, len, cap, num, wcslen( num ) );
    }
    case JsonValueType_String:
    {
        HSTRING s;
        if (FAILED(hr = IJsonValue_GetString( json, &s ))) return hr;
        hr = append_json_string( buf, len, cap, WindowsGetStringRawBuffer( s, NULL ) );
        WindowsDeleteString( s );
        return hr;
    }
    default:
        return append( buf, len, cap, L"null", 4 );
    }
}

static HRESULT WINAPI value_Stringify( IJsonValue *iface, HSTRING *value )
{
    struct json_object *impl = value_impl( iface );
    IIterable_IKeyValuePair_HSTRING_IInspectable *iterable;
    IIterator_IKeyValuePair_HSTRING_IInspectable *iter;
    WCHAR *buf = NULL;
    SIZE_T len = 0, cap = 0;
    boolean has;
    int first = 1;
    HRESULT hr;

    trace( "Stringify" );
    if (!value) return E_POINTER;
    if (FAILED(hr = IMap_HSTRING_IInspectable_QueryInterface( impl->members, &IID_IIterable_IKeyValuePair_HSTRING_IInspectable,
                                                              (void **)&iterable ))) return hr;
    hr = IIterable_IKeyValuePair_HSTRING_IInspectable_First( iterable, &iter );
    IIterable_IKeyValuePair_HSTRING_IInspectable_Release( iterable );
    if (FAILED(hr)) return hr;

    hr = append( &buf, &len, &cap, L"{", 1 );
    while (SUCCEEDED(hr) && SUCCEEDED(IIterator_IKeyValuePair_HSTRING_IInspectable_get_HasCurrent( iter, &has )) && has)
    {
        IKeyValuePair_HSTRING_IInspectable *pair;
        IInspectable *item;
        IJsonValue *json;
        HSTRING key;

        if (FAILED(hr = IIterator_IKeyValuePair_HSTRING_IInspectable_get_Current( iter, &pair ))) break;
        IKeyValuePair_HSTRING_IInspectable_get_Key( pair, &key );
        IKeyValuePair_HSTRING_IInspectable_get_Value( pair, &item );
        if (!first) hr = append( &buf, &len, &cap, L",", 1 );
        first = 0;
        if (SUCCEEDED(hr)) hr = append_json_string( &buf, &len, &cap, WindowsGetStringRawBuffer( key, NULL ) );
        if (SUCCEEDED(hr)) hr = append( &buf, &len, &cap, L":", 1 );
        if (SUCCEEDED(hr))
        {
            if (item && SUCCEEDED(IInspectable_QueryInterface( item, &IID_IJsonValue, (void **)&json )))
            {
                hr = append_value( &buf, &len, &cap, json );
                IJsonValue_Release( json );
            }
            else hr = append( &buf, &len, &cap, L"null", 4 );
        }
        if (item) IInspectable_Release( item );
        WindowsDeleteString( key );
        IKeyValuePair_HSTRING_IInspectable_Release( pair );
        IIterator_IKeyValuePair_HSTRING_IInspectable_MoveNext( iter, &has );
    }
    IIterator_IKeyValuePair_HSTRING_IInspectable_Release( iter );
    if (SUCCEEDED(hr)) hr = append( &buf, &len, &cap, L"}", 1 );
    if (SUCCEEDED(hr)) hr = WindowsCreateString( buf, len, value );
    free( buf );
    return hr;
}

static HRESULT WINAPI value_GetString( IJsonValue *iface, HSTRING *value ) { return E_ILLEGAL_METHOD_CALL; }
static HRESULT WINAPI value_GetNumber( IJsonValue *iface, DOUBLE *value ) { return E_ILLEGAL_METHOD_CALL; }
static HRESULT WINAPI value_GetBoolean( IJsonValue *iface, boolean *value ) { return E_ILLEGAL_METHOD_CALL; }
static HRESULT WINAPI value_GetArray( IJsonValue *iface, IJsonArray **value ) { return E_ILLEGAL_METHOD_CALL; }

static HRESULT WINAPI value_GetObject( IJsonValue *iface, IJsonObject **value )
{
    struct json_object *impl = value_impl( iface );

    if (!value) return E_POINTER;
    *value = &impl->IJsonObject_iface;
    IJsonObject_AddRef( *value );
    return S_OK;
}

static const IJsonValueVtbl value_vtbl =
{
    .QueryInterface = value_QueryInterface,
    .AddRef = value_AddRef,
    .Release = value_Release,
    .GetIids = value_GetIids,
    .GetRuntimeClassName = value_GetRuntimeClassName,
    .GetTrustLevel = value_GetTrustLevel,
    .get_ValueType = value_get_ValueType,
    .Stringify = value_Stringify,
    .GetString = value_GetString,
    .GetNumber = value_GetNumber,
    .GetBoolean = value_GetBoolean,
    .GetArray = value_GetArray,
    .GetObject = value_GetObject,
};

/* ---- IMap<HSTRING, IJsonValue>: the members map of the object (a PropertySet) with the value type narrowed ---- */

DEFINE_INSPECTABLE( map, IMap_HSTRING_IJsonValue, IMap_iface )

static HRESULT WINAPI map_Lookup( IMap_HSTRING_IJsonValue *iface, HSTRING key, IJsonValue **value )
{
    trace( "IMap::Lookup %ls", WindowsGetStringRawBuffer( key, NULL ) );
    return IMap_HSTRING_IInspectable_Lookup( map_impl( iface )->members, key, (IInspectable **)value );
}

static HRESULT WINAPI map_get_Size( IMap_HSTRING_IJsonValue *iface, UINT32 *size )
{
    trace( "IMap::get_Size" );
    return IMap_HSTRING_IInspectable_get_Size( map_impl( iface )->members, size );
}

static HRESULT WINAPI map_HasKey( IMap_HSTRING_IJsonValue *iface, HSTRING key, boolean *found )
{
    trace( "IMap::HasKey %ls", WindowsGetStringRawBuffer( key, NULL ) );
    return IMap_HSTRING_IInspectable_HasKey( map_impl( iface )->members, key, found );
}

static HRESULT WINAPI map_GetView( IMap_HSTRING_IJsonValue *iface, IMapView_HSTRING_IJsonValue **view )
{
    trace( "IMap::GetView" );
    return IMap_HSTRING_IInspectable_GetView( map_impl( iface )->members, (IMapView_HSTRING_IInspectable **)view );
}

static HRESULT WINAPI map_Insert( IMap_HSTRING_IJsonValue *iface, HSTRING key, IJsonValue *value, boolean *replaced )
{
    trace( "IMap::Insert %ls", WindowsGetStringRawBuffer( key, NULL ) );
    return IMap_HSTRING_IInspectable_Insert( map_impl( iface )->members, key, (IInspectable *)value, replaced );
}

static HRESULT WINAPI map_Remove( IMap_HSTRING_IJsonValue *iface, HSTRING key )
{
    trace( "IMap::Remove %ls", WindowsGetStringRawBuffer( key, NULL ) );
    return IMap_HSTRING_IInspectable_Remove( map_impl( iface )->members, key );
}

static HRESULT WINAPI map_Clear( IMap_HSTRING_IJsonValue *iface )
{
    trace( "IMap::Clear" );
    return IMap_HSTRING_IInspectable_Clear( map_impl( iface )->members );
}

static const IMap_HSTRING_IJsonValueVtbl map_vtbl =
{
    .QueryInterface = map_QueryInterface,
    .AddRef = map_AddRef,
    .Release = map_Release,
    .GetIids = map_GetIids,
    .GetRuntimeClassName = map_GetRuntimeClassName,
    .GetTrustLevel = map_GetTrustLevel,
    .Lookup = map_Lookup,
    .get_Size = map_get_Size,
    .HasKey = map_HasKey,
    .GetView = map_GetView,
    .Insert = map_Insert,
    .Remove = map_Remove,
    .Clear = map_Clear,
};

/* ---- IIterable<IKeyValuePair<HSTRING, IJsonValue>> ---- */

DEFINE_INSPECTABLE( iterable, IIterable_IKeyValuePair_HSTRING_IJsonValue, IIterable_iface )

static HRESULT WINAPI iterable_First( IIterable_IKeyValuePair_HSTRING_IJsonValue *iface,
                                      IIterator_IKeyValuePair_HSTRING_IJsonValue **first )
{
    IIterable_IKeyValuePair_HSTRING_IInspectable *inner;
    HRESULT hr;

    trace( "IIterable::First" );
    if (FAILED(hr = IMap_HSTRING_IInspectable_QueryInterface( iterable_impl( iface )->members,
                                                              &IID_IIterable_IKeyValuePair_HSTRING_IInspectable, (void **)&inner )))
        return hr;
    hr = IIterable_IKeyValuePair_HSTRING_IInspectable_First( inner, (IIterator_IKeyValuePair_HSTRING_IInspectable **)first );
    IIterable_IKeyValuePair_HSTRING_IInspectable_Release( inner );
    return hr;
}

static const IIterable_IKeyValuePair_HSTRING_IJsonValueVtbl iterable_vtbl =
{
    .QueryInterface = iterable_QueryInterface,
    .AddRef = iterable_AddRef,
    .Release = iterable_Release,
    .GetIids = iterable_GetIids,
    .GetRuntimeClassName = iterable_GetRuntimeClassName,
    .GetTrustLevel = iterable_GetTrustLevel,
    .First = iterable_First,
};

/* ---- the activation factory ---- */

struct factory
{
    IActivationFactory IActivationFactory_iface;
    LONG ref;
};

static inline struct factory *factory_impl( IActivationFactory *iface )
{
    return CONTAINING_RECORD( iface, struct factory, IActivationFactory_iface );
}

static HRESULT WINAPI factory_QueryInterface( IActivationFactory *iface, REFIID iid, void **out )
{
    struct factory *impl = factory_impl( iface );

    if (IsEqualGUID( iid, &IID_IUnknown ) || IsEqualGUID( iid, &IID_IInspectable ) ||
        IsEqualGUID( iid, &IID_IAgileObject ) || IsEqualGUID( iid, &IID_IActivationFactory ))
    {
        *out = &impl->IActivationFactory_iface;
        InterlockedIncrement( &impl->ref );
        return S_OK;
    }
    trace( "factory: %s not implemented", guid_str( iid ) );
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG WINAPI factory_AddRef( IActivationFactory *iface )
{
    return InterlockedIncrement( &factory_impl( iface )->ref );
}

static ULONG WINAPI factory_Release( IActivationFactory *iface )
{
    return InterlockedDecrement( &factory_impl( iface )->ref );
}

static HRESULT WINAPI factory_GetIids( IActivationFactory *iface, ULONG *count, IID **iids )
{
    return E_NOTIMPL;
}

static HRESULT WINAPI factory_GetRuntimeClassName( IActivationFactory *iface, HSTRING *name )
{
    return object_class_name( name );
}

static HRESULT WINAPI factory_GetTrustLevel( IActivationFactory *iface, TrustLevel *level )
{
    *level = BaseTrust;
    return S_OK;
}

static HRESULT WINAPI factory_ActivateInstance( IActivationFactory *iface, IInspectable **instance )
{
    IPropertySet *property_set;
    struct json_object *impl;
    HSTRING_HEADER header;
    HSTRING class_name;
    HRESULT hr;

    trace( "ActivateInstance" );
    *instance = NULL;
    if (!(impl = calloc( 1, sizeof(*impl) ))) return E_OUTOFMEMORY;

    impl->IJsonObject_iface.lpVtbl = VTBL( &object_vtbl );
    impl->IJsonValue_iface.lpVtbl = VTBL( &value_vtbl );
    impl->IMap_iface.lpVtbl = VTBL( &map_vtbl );
    impl->IIterable_iface.lpVtbl = VTBL( &iterable_vtbl );
    impl->ref = 1;

    WindowsCreateStringReference( CLASS_PROPERTY_SET, ARRAYSIZE(CLASS_PROPERTY_SET) - 1, &header, &class_name );
    if (FAILED(hr = RoActivateInstance( class_name, (IInspectable **)&property_set ))) goto failed;
    hr = IPropertySet_QueryInterface( property_set, &IID_IMap_HSTRING_IInspectable, (void **)&impl->members );
    IPropertySet_Release( property_set );
    if (FAILED(hr)) goto failed;

    *instance = (IInspectable *)&impl->IJsonObject_iface;
    return S_OK;

failed:
    free( impl );
    return hr;
}

static const IActivationFactoryVtbl factory_vtbl =
{
    .QueryInterface = factory_QueryInterface,
    .AddRef = factory_AddRef,
    .Release = factory_Release,
    .GetIids = factory_GetIids,
    .GetRuntimeClassName = factory_GetRuntimeClassName,
    .GetTrustLevel = factory_GetTrustLevel,
    .ActivateInstance = factory_ActivateInstance,
};

static struct factory json_object_factory = { { VTBL( &factory_vtbl ) }, 1 };

HRESULT WINAPI DllGetActivationFactory( HSTRING class_id, IActivationFactory **factory )
{
    const WCHAR *name = WindowsGetStringRawBuffer( class_id, NULL );

    *factory = NULL;
    if (name && !wcscmp( name, CLASS_JSON_OBJECT ))
    {
        *factory = &json_object_factory.IActivationFactory_iface;
        IActivationFactory_AddRef( *factory );
        return S_OK;
    }
    return CLASS_E_CLASSNOTAVAILABLE;
}

HRESULT WINAPI DllCanUnloadNow( void )
{
    return S_FALSE;
}
