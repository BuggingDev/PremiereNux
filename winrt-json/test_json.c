/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Self-test of premierenux_json.dll under Wine: activates Windows.Data.Json.JsonObject the way Premiere Pro does
 * (SetNamedValue, then IMap<HSTRING, IJsonValue>) and prints what comes back.
 *   wine test_json.exe        exit code 0 = every check passed
 */
#define COBJMACROS
#define INITGUID
#include <stdio.h>
#include <windows.h>
#include <winstring.h>
#include <activation.h>
#include <roapi.h>
#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Foundation_Collections
#include <windows.foundation.h>
#define WIDL_using_Windows_Data_Json
#include <windows.data.json.h>

static int failed;

#define CHECK( cond, ... ) do { if (cond) printf( "ok    " __VA_ARGS__ ); else { printf( "FAIL  " __VA_ARGS__ ); failed++; } printf( "\n" ); } while (0)

static HSTRING mk( HSTRING_HEADER *h, const WCHAR *s )
{
    HSTRING r;
    WindowsCreateStringReference( s, wcslen( s ), h, &r );
    return r;
}

int main( void )
{
    HSTRING_HEADER h1, h2, h3;
    IInspectable *obj;
    IMap_HSTRING_IJsonValue *map;
    IJsonObject *jo;
    IJsonValue *as_value, *val, *got;
    IJsonValueStatics *statics;
    IIterable_IKeyValuePair_HSTRING_IJsonValue *iterable;
    IIterator_IKeyValuePair_HSTRING_IJsonValue *iter;
    HSTRING text;
    boolean has;
    UINT32 size;
    HRESULT hr;

    RoInitialize( RO_INIT_MULTITHREADED );

    hr = RoActivateInstance( mk( &h1, L"Windows.Data.Json.JsonObject" ), &obj );
    CHECK( hr == S_OK, "RoActivateInstance(JsonObject) = %08lx", hr );
    if (FAILED(hr)) return 1;

    hr = IInspectable_QueryInterface( obj, &IID_IJsonObject, (void **)&jo );
    CHECK( hr == S_OK, "QueryInterface(IJsonObject) = %08lx", hr );
    hr = IInspectable_QueryInterface( obj, &IID_IMap_HSTRING_IJsonValue, (void **)&map );
    CHECK( hr == S_OK, "QueryInterface(IMap<HSTRING, IJsonValue>) = %08lx", hr );
    hr = IInspectable_QueryInterface( obj, &IID_IJsonValue, (void **)&as_value );
    CHECK( hr == S_OK, "QueryInterface(IJsonValue) = %08lx", hr );
    hr = IInspectable_QueryInterface( obj, &IID_IIterable_IKeyValuePair_HSTRING_IJsonValue, (void **)&iterable );
    CHECK( hr == S_OK, "QueryInterface(IIterable<IKeyValuePair<HSTRING, IJsonValue>>) = %08lx", hr );
    if (failed) return 1;

    hr = RoGetActivationFactory( mk( &h1, L"Windows.Data.Json.JsonValue" ), &IID_IJsonValueStatics, (void **)&statics );
    CHECK( hr == S_OK, "JsonValue statics = %08lx", hr );
    hr = IJsonValueStatics_CreateStringValue( statics, mk( &h1, L"24.4.1" ), &val );
    CHECK( hr == S_OK, "CreateStringValue = %08lx", hr );

    hr = IJsonObject_SetNamedValue( jo, mk( &h1, L"app_version" ), val );
    CHECK( hr == S_OK, "SetNamedValue(app_version) = %08lx", hr );

    hr = IMap_HSTRING_IJsonValue_HasKey( map, mk( &h1, L"app_version" ), &has );
    CHECK( hr == S_OK && has, "IMap::HasKey(app_version) = %08lx has=%d", hr, has );
    hr = IMap_HSTRING_IJsonValue_get_Size( map, &size );
    CHECK( hr == S_OK && size == 1, "IMap::get_Size = %u", size );
    hr = IMap_HSTRING_IJsonValue_Lookup( map, mk( &h1, L"app_version" ), &got );
    CHECK( hr == S_OK && got == val, "IMap::Lookup returns the stored value = %08lx", hr );

    hr = IJsonObject_GetNamedString( jo, mk( &h1, L"app_version" ), &text );
    CHECK( hr == S_OK && !wcscmp( WindowsGetStringRawBuffer( text, NULL ), L"24.4.1" ), "GetNamedString = %ls",
           SUCCEEDED(hr) ? WindowsGetStringRawBuffer( text, NULL ) : L"?" );

    hr = IMap_HSTRING_IJsonValue_Insert( map, mk( &h2, L"second" ), val, &has );
    CHECK( hr == S_OK && !has, "IMap::Insert(second) = %08lx replaced=%d", hr, has );

    hr = IIterable_IKeyValuePair_HSTRING_IJsonValue_First( iterable, &iter );
    CHECK( hr == S_OK, "IIterable::First = %08lx", hr );
    if (SUCCEEDED(hr))
    {
        int n = 0;
        while (SUCCEEDED(IIterator_IKeyValuePair_HSTRING_IJsonValue_get_HasCurrent( iter, &has )) && has)
        {
            IKeyValuePair_HSTRING_IJsonValue *pair;
            HSTRING key;
            IIterator_IKeyValuePair_HSTRING_IJsonValue_get_Current( iter, &pair );
            IKeyValuePair_HSTRING_IJsonValue_get_Key( pair, &key );
            printf( "      item %d: %ls\n", n++, WindowsGetStringRawBuffer( key, NULL ) );
            WindowsDeleteString( key );
            IKeyValuePair_HSTRING_IJsonValue_Release( pair );
            IIterator_IKeyValuePair_HSTRING_IJsonValue_MoveNext( iter, &has );
        }
        CHECK( n == 2, "iterated %d items", n );
    }

    hr = IJsonValue_Stringify( as_value, &text );
    CHECK( hr == S_OK, "Stringify = %ls", SUCCEEDED(hr) ? WindowsGetStringRawBuffer( text, NULL ) : L"?" );

    hr = IMap_HSTRING_IJsonValue_Remove( map, mk( &h3, L"second" ) );
    CHECK( hr == S_OK, "IMap::Remove(second) = %08lx", hr );
    hr = IMap_HSTRING_IJsonValue_Lookup( map, mk( &h3, L"second" ), &got );
    CHECK( FAILED(hr), "IMap::Lookup of a removed key fails = %08lx", hr );

    printf( failed ? "%d check(s) failed\n" : "all checks passed\n", failed );
    return failed != 0;
}
