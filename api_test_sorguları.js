import axios from "axios";

const BASE_URL = "https://api.gain.tv/2da7kf8jf"; 
const ENDPOINT = "/CALL/BackofficeUserManager/getBackofficeUserList/default";

const BEARER_TOKEN = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9qZWN0SWQiOiIyZGE3a2Y4amYiLCJpZGVudGl0eSI6ImJhY2tvZmZpY2VfdXNlciIsImFub255bW91cyI6ZmFsc2UsInVzZXJJZCI6Ik1ybWRPbGlTcDMzQk1nR2NvUGhoVmRhdCIsImNsYWltcyI6eyJuYW1lIjoiQmF0dWhhbiDDh2FrxLFyIiwiZW1haWwiOiJiYXR1aGFuY2FraXJAZ2Fpbi5jb20udHIiLCJzdGF0dXMiOiJhY3RpdmUiLCJyb2xlIjoiYWRtaW4ifSwic2Vzc2lvbklkIjoiMDJkYWI4MTg5YjhkNDAwZGI2YWFhMWQxZjI3N2Y4OGYiLCJpYXQiOjE3NzQ2MTE3MzksImV4cCI6MTc3NzIwMzczOX0.Q1KfMlkroAVfVHXSagTCIYreY1aHXg5Ew4hQSke2hkj2y4ULOBn1uBWgrqpUwHRKPqI4BTWBs7_v7mdZOcAxf-tTTAHW_oXMAoxO-IenbNsfsq7RIzTAiY_F5utxRUOMKxY-ns2uqLg0VQpzAXz-YFezNT6PHzFLLgYU5KVR-YzzbSqkbjki6daMfFA2tAFQvJvLEO_bFGz2wkLg27r16kC-kegR_cH5d3zrlCFR8MFWVNeVWpzNEJRUZE_SzCf_duy1KA2J-iGkSvd1cf3InZTOo4c-ZJLHE6tsTjV_-TYZBjFQhuYnpbM4b7H1nU6kK23T6Q-NB8Updxh1HPdNgQ";

async function getUsers() {
  try {
    const response = await axios.get(`${BASE_URL}${ENDPOINT}`, {
      headers: {
        Authorization: `Bearer ${BEARER_TOKEN}`,
        "Content-Type": "application/json"
      }
    });

    console.log("Status:", response.status);
    console.log("Data:", JSON.stringify(response.data, null, 2));

  } catch (error) {
    if (error.response) {
      console.error("Error Status:", error.response.status);
      console.error("Error Data:", error.response.data);
    } else {
      console.error("Error:", error.message);
    }
  }
}

getUsers();