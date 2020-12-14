# -*- coding: utf-8 -*-
"""
Created on Mon Dec 14 08:44:09 2020

@author: R.Armstrong

Get the phone numbers and IMEI from cell equipped Airwalls
"""

import requests
import time


def get_airwall_list(conductor, client_id, api_key):
    """
    Get the list of Airwalls from the conductor

    Parameters
    ----------
    conductor : String (URL)
        URL of the Conductor (either by name or IP address).
    client_id : String
        Client API ID.
    api_key : String
        API KEy.

    Returns
    -------
    list of UUID of Airwalls

    """
    # set up the URL for the request
    url = conductor + "/api/v1/hipservices"
    
    # Make the request (GET, POST, etc.)
    response = requests.get(url, 
                            headers={'X-API-Client-ID': client_id, 'X-API-Token': api_key}, 
                            verify=False)
    
    # Process the response
    json_values = response.json()
    
    # Returns the processed values (In this case everythin)
    return json_values

def start_diag_report(conductor, client_id, api_key, uuid):
    """
    Start the diagnostic report on UUID airwall

    Parameters
    ----------
    conductor : String (URL)
        URL of the Conductor (either by name or IP address).
    client_id : String
        Client API ID.
    api_key : String
        API KEy.
    uuid : String
        UUID of the Airwall.

    Returns
    -------
    Success/failure  (Job_Id?)

    """
    # set up the URL for the request
    url = conductor + "/api/v1/hipservices/{}/diagnostic".format(uuid)
    
    # Make the request (GET, POST, etc.)
    response = requests.post(url, 
                             headers={'X-API-Client-ID': client_id, 'X-API-Token': api_key}, 
                             verify=False)
    
    # Process the response
    response_json = response.json()
    
    # return the values we want (In this case everything)
    return response.json() 

def get_diag_report(conductor, client_id, api_key, uuid):
    """
    Get the diagnostic report from UUDI

    Parameters
    ----------
    conductor : String (URL)
        URL of the Conductor (either by name or IP address).
    client_id : String
        Client API ID.
    api_key : String
        API KEy.
    uuid : String
        UUID of the Airwall.


    Returns
    -------
    Huge blob of text of the diagnostic report (See example file)
    """
    # set up the URL for the request
    url = conductor + "/api/v1/hipservices/{}/diagnostic".format(uuid)
    
    # Make the request (GET, POST, etc.)
    response = requests.get(url, 
                            headers={'X-API-Client-ID': client_id, 'X-API-Token': api_key}, 
                            verify=False)
    
    # Process the response
    response_text = response.text
    
    # Return the processed results (In this case everything)
    return response.text

if __name__ == '__main__':
    # Set up the information needed to use the API
    # These should come from arguments, the environment, or a config file
    conductor = 'https://conductor.helixlabs.tech'
    client_id = 'RxayAHgegI67s1jy_cuRTQ'
    api_key = 'u5kep6CYFqSo3ttZyexaWw'
    
    # Get the list
    airwalls = get_airwall_list(conductor, client_id, api_key)
    # Walk the list and start diag reports

    for airwall in airwalls:
        start_diag_report(conductor, client_id, api_key, airwall['uuid'])

    # Now go get the diag reports (check job status?)
    time.sleep(30)

    for airwall in airwalls:
        # add values here from the JSON to identify this unit
        unit_info = airwall['title']
        print(unit_info)
        report = get_diag_report(conductor, client_id, api_key, airwall['uuid'])
        # parse out the IMEI and MISDN
        for line in report.splitlines():
            if 'imei' in line:
                print(line)
            if 'msisdn' in line:
                print(line)

        